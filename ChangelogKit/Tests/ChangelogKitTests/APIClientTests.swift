import Foundation
import Testing
@testable import ChangelogKit

/// Answers requests from a table, and remembers what was asked. Each test
/// uses its own host, so tests running together never share answers.
final class StubProtocol: URLProtocol, @unchecked Sendable {
  struct Answer: Sendable { var status: Int; var body: String; var headers: [String: String] = [:] }
  nonisolated(unsafe) static var answers: [String: Answer] = [:]
  nonisolated(unsafe) static var seen: [String: [URLRequest]] = [:]
  static let lock = NSLock()

  static func set(_ host: String, _ answer: Answer) { lock.withLock { answers[host] = answer; seen[host] = [] } }
  static func requests(_ host: String) -> [URLRequest] { lock.withLock { seen[host] ?? [] } }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    let host = request.url?.host ?? ""
    var copy = request
    if copy.httpBody == nil, let stream = request.httpBodyStream {
      stream.open()
      var data = Data()
      let size = 4096
      let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
      while stream.hasBytesAvailable {
        let n = stream.read(buffer, maxLength: size)
        if n <= 0 { break }
        data.append(buffer, count: n)
      }
      buffer.deallocate()
      stream.close()
      copy.httpBody = data
    }
    let answer = Self.lock.withLock { () -> Answer? in
      Self.seen[host, default: []].append(copy)
      return Self.answers[host]
    }
    guard let answer else {
      client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
      return
    }
    let response = HTTPURLResponse(url: request.url!, statusCode: answer.status, httpVersion: "HTTP/1.1", headerFields: answer.headers)!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Data(answer.body.utf8))
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}

func stubbedClient(_ host: String) -> APIClient {
  let config = URLSessionConfiguration.ephemeral
  config.protocolClasses = [StubProtocol.self]
  return APIClient(baseURL: URL(string: "https://\(host)")!, token: "rn_" + String(repeating: "A", count: 43),
                   userAgent: "Changelog/0.1 (iOS 26.1)", session: URLSession(configuration: config))
}

@Suite struct APIClientTests {
  @Test func readsMe() async throws {
    StubProtocol.set("me.test", .init(status: 200, body: """
      {"today":"2026-10-29","version":"4.5.137","tz":"America/Chicago","send_time":"06:30",
       "wrote_today":false,"streak":12,"paused_until":null,"status":"active","show_badges":true,
       "days":[{"date":"2026-10-29","version":"4.5.137"},{"date":"2026-10-30","version":"4.5.138"}],
       "token":{"name":"Changelog on my iPhone","scopes":["notes:write","activity"],"expires_at":null},
       "api_version":"1.0.0","added_later":"ignored"}
      """))
    let me = try await stubbedClient("me.test").me()
    #expect(me.version == "4.5.137")
    #expect(me.version(on: "2026-10-30") == "4.5.138")
    #expect(me.version(on: "2026-11-30") == nil)
    #expect(me.token.scopes.contains("activity"))
    let request = try #require(StubProtocol.requests("me.test").first)
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer rn_" + String(repeating: "A", count: 43))
    #expect(request.value(forHTTPHeaderField: "User-Agent") == "Changelog/0.1 (iOS 26.1)")
    #expect(request.url?.path == "/v1/me")
  }

  @Test func createsANoteWithItsKey() async throws {
    StubProtocol.set("create.test", .init(status: 201, body: """
      {"note":{"id":"t-3f9c","date":"2026-10-28","version":"4.5.136","revision":"9c1e5b0a2f7d4e3c8b6a1f0e","token":"Terminal"},
       "unlocked":[{"key":"api","name":"API release"}]}
      """))
    let receipt = try await stubbedClient("create.test").createNote(
      NoteRequest(text: "Ran the river loop #running", writtenAt: "2026-10-28T23:58:40-05:00"), idempotencyKey: "k-1")
    #expect(receipt.note.version == "4.5.136")
    #expect(receipt.unlocked?.first?.name == "API release")
    #expect(receipt.note.revision == "9c1e5b0a2f7d4e3c8b6a1f0e")
    let request = try #require(StubProtocol.requests("create.test").first)
    #expect(request.httpMethod == "POST")
    #expect(request.value(forHTTPHeaderField: "Idempotency-Key") == "k-1")
    let body = try JSONSerialization.jsonObject(with: try #require(request.httpBody)) as? [String: String]
    #expect(body == ["text": "Ran the river loop #running", "written_at": "2026-10-28T23:58:40-05:00"])
  }

  @Test func readsTheErrorShape() async throws {
    StubProtocol.set("limit.test", .init(status: 429, body: #"{"error":{"code":"rate_limited","message":"That's today's 100 notes."}}"#,
                                         headers: ["Retry-After": "3600"]))
    do {
      _ = try await stubbedClient("limit.test").createNote(NoteRequest(text: "x"), idempotencyKey: "k")
      Issue.record("expected an error")
    } catch {
      #expect(error.code == "rate_limited")
      #expect(error.retryAfter == 3600)
      #expect(error.retryable)
      #expect(!error.signedOut)
    }
  }

  @Test func aRevokedTokenSignsOut() async throws {
    StubProtocol.set("revoked.test", .init(status: 401, body: #"{"error":{"code":"token_revoked","message":"This token was revoked."}}"#))
    do {
      _ = try await stubbedClient("revoked.test").me()
      Issue.record("expected an error")
    } catch {
      #expect(error.signedOut)
      #expect(!error.retryable)
    }
  }

  @Test func anAnswerWithoutTheShapeStillReads() async throws {
    StubProtocol.set("gateway.test", .init(status: 502, body: "<html>Bad gateway</html>"))
    do {
      _ = try await stubbedClient("gateway.test").me()
      Issue.record("expected an error")
    } catch {
      #expect(error.code == "unavailable")
      #expect(error.retryable)
    }
  }

  @Test func offlineIsRetryable() async throws {
    do {
      _ = try await stubbedClient("nowhere.test").me()
      Issue.record("expected an error")
    } catch {
      #expect(error.code == "network")
      #expect(error.status == 0)
      #expect(error.retryable)
    }
  }

  /// Busy or failing, the server's sentence is for developers: the app says
  /// it in its own words, and keeps the code.
  @Test func busyIsSaidInTheAppsWords() async throws {
    let developers = #"{"error":{"code":"%@","message":"Try again shortly with the same Idempotency-Key."}}"#
    StubProtocol.set("queue-unavailable.test", .init(status: 503, body: developers.replacingOccurrences(of: "%@", with: "unavailable")))
    StubProtocol.set("queue-busy.test", .init(status: 409, body: developers.replacingOccurrences(of: "%@", with: "busy")))
    for (host, code) in [("queue-unavailable.test", "unavailable"), ("queue-busy.test", "busy")] {
      do {
        _ = try await stubbedClient(host).createNote(NoteRequest(text: "x"), idempotencyKey: "k")
        Issue.record("expected an error")
      } catch {
        #expect(error.code == code && error.retryable)
        #expect(error.message == APIClient.busy)
      }
    }
  }

  /// A 2xx this build can't read is done, not refused and not retried.
  @Test func aDoneAnswerItCantReadIsDone() async throws {
    StubProtocol.set("queue-unread.test", .init(status: 201, body: #"{"receipt":{"shape":"from a newer server"}}"#))
    do {
      _ = try await stubbedClient("queue-unread.test").createNote(NoteRequest(text: "x"), idempotencyKey: "k")
      Issue.record("expected an error")
    } catch {
      #expect(error.done && !error.retryable && !error.signedOut)
    }
  }

  @Test func deleteTakesAnEmptyAnswer() async throws {
    StubProtocol.set("delete.test", .init(status: 204, body: ""))
    try await stubbedClient("delete.test").deleteNote(date: "2026-10-29", id: "t-1", idempotencyKey: "k")
    #expect(StubProtocol.requests("delete.test").first?.url?.path == "/v1/notes/2026-10-29/t-1")
  }

  @Test func activityAsksSinceACursor() async throws {
    StubProtocol.set("activity.test", .init(status: 200, body: """
      {"items":[{"id":"2026-10-29T14:02:11.000Z#note.added#t-1","at":"2026-10-29T14:02:11.000Z","kind":"note.added",
                 "via":"token","token":"Terminal","client":"curl","day":"2026-10-29","version":"4.5.137","note":"t-1","files":0},
                {"id":"x","at":"2026-10-29T11:30:00.000Z","kind":"mail","via":"email","day":"2026-10-29","outcome":"note"}],
       "next":null}
      """))
    let page = try await stubbedClient("activity.test").activity(after: "abc", kinds: ["note", "mail"])
    #expect(page.items.map(\.family) == ["note", "mail"])
    #expect(page.items.first?.token == "Terminal")
    let query = StubProtocol.requests("activity.test").first?.url?.query ?? ""
    #expect(query.contains("after=abc"))
    #expect(query.contains("kinds=note,mail"))
  }

  @Test func aMismatchCarriesTheCurrentRevision() async throws {
    StubProtocol.set("mismatch.test", .init(status: 409, body: """
      {"error":{"code":"revision_mismatch","message":"This note changed since it was read.","revision":"0d4f9a7c1b2e3d5f6a8b9c0e"}}
      """))
    do {
      _ = try await stubbedClient("mismatch.test").editNote(date: "2026-10-29", id: "t-1", text: "x", revision: "old", idempotencyKey: "k")
      Issue.record("expected an error")
    } catch {
      #expect(error.code == "revision_mismatch")
      #expect(error.revision == "0d4f9a7c1b2e3d5f6a8b9c0e")
      #expect(!error.retryable)
    }
    let body = try JSONSerialization.jsonObject(with: try #require(StubProtocol.requests("mismatch.test").first?.httpBody)) as? [String: String]
    #expect(body == ["text": "x", "revision": "old"])
  }

  @Test func performSendsEachWriteUnderItsKey() async throws {
    StubProtocol.set("perform.test", .init(status: 200, body: #"{"pinned":["running"],"recent":[]}"#))
    let item = OutboxItem(id: UUID(), operation: .pins(["running"]), queuedAt: .now, attempts: 0, refusal: nil)
    let result = try await stubbedClient("perform.test").perform(item)
    #expect(result == .pinned(Tags(pinned: ["running"], recent: [], windowDays: nil)))
    let request = try #require(StubProtocol.requests("perform.test").first)
    #expect(request.httpMethod == "PUT")
    #expect(request.url?.path == "/v1/tags/pinned")
    #expect(request.value(forHTTPHeaderField: "Idempotency-Key") == item.idempotencyKey)
  }
}
