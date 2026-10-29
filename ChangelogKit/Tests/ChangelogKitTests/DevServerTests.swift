import Foundation
import Testing
@testable import ChangelogKit

/// The client against the real `/v1`, served by Release Notes' dev server
/// (`node --import tsx tools/dev-server.ts`, fictional in-memory data). It
/// runs only when the token the dev server prints is in the environment:
///
///     CHANGELOG_DEV_TOKEN=rn_... swift test --package-path ChangelogKit
///
/// `CHANGELOG_DEV_URL` points elsewhere than http://localhost:8790. Never
/// point it at production: these tests write.
enum DevServer {
  static let token = ProcessInfo.processInfo.environment["CHANGELOG_DEV_TOKEN"]
  static let url = ProcessInfo.processInfo.environment["CHANGELOG_DEV_URL"].flatMap(URL.init(string:)) ?? APIClient.devServer
  /// Only with a token, and only against this Mac.
  static var enabled: Bool { token != nil && ["localhost", "127.0.0.1"].contains(url.host() ?? "") }
  static func client() -> APIClient {
    APIClient(baseURL: url, token: token ?? "", userAgent: "Changelog/0.1 (dev tests)",
              session: URLSession(configuration: .ephemeral))
  }
}

@Suite(.enabled(if: DevServer.enabled), .serialized)
struct DevServerTests {
  @Test func meDecodes() async throws {
    let me = try await DevServer.client().me()
    #expect(me.apiVersion.hasPrefix("1."))
    #expect(me.token.scopes.contains("notes:write"))
    #expect(me.version(on: me.today) == me.version)
    #expect(me.days.count > 1)
  }

  @Test func outboxFilesOnceAndTheNoteReadsBack() async throws {
    let client = DevServer.client(), outbox = Outbox(file: nil)
    let item = try await outbox.enqueue(text: "Dev test from ChangelogKit #devtest")
    let report = await outbox.flush { (item) async throws(APIError) -> OutboxResult in try await client.perform(item) }
    #expect(report.stopped == nil)
    let receipt = try #require(report.filed.first)
    #expect(receipt.note.token != nil)
    // The same key again is the same note, never a second one.
    let again = try await client.perform(item)
    guard case .filed(let replay) = again else { Issue.record("not filed"); return }
    #expect(replay.note.id == receipt.note.id)

    let read = try await client.note(date: receipt.note.date, id: receipt.note.id)
    #expect(read.text == "Dev test from ChangelogKit #devtest")
    #expect(read.revision == receipt.note.revision)
  }

  @Test func appendEditConflictAndDelete() async throws {
    let client = DevServer.client()
    let made = try await client.createNote(NoteRequest(text: "To change #devtest"), idempotencyKey: UUID().uuidString.lowercased())
    let note = made.note
    let appended = try await client.appendNote(date: note.date, id: note.id, text: "A line more", idempotencyKey: UUID().uuidString.lowercased())
    #expect(appended.revision != note.revision)
    // An edit from the revision before the append is refused, with the current one.
    do {
      _ = try await client.editNote(date: note.date, id: note.id, text: "Stale", revision: note.revision,
                                    idempotencyKey: UUID().uuidString.lowercased())
      Issue.record("a stale edit went through")
    } catch {
      #expect(error.code == "revision_mismatch")
      #expect(error.revision == appended.revision)
      #expect(!error.retryable)
    }
    let edited = try await client.editNote(date: note.date, id: note.id, text: "Changed #devtest", revision: appended.revision,
                                           idempotencyKey: UUID().uuidString.lowercased())
    #expect(try await client.note(date: note.date, id: note.id).text == "Changed #devtest")
    #expect(edited.id == note.id)
    try await client.deleteNote(date: note.date, id: note.id, idempotencyKey: UUID().uuidString.lowercased())
    do {
      _ = try await client.note(date: note.date, id: note.id)
      Issue.record("a deleted note still reads")
    } catch {
      #expect(error.status == 404)
    }
  }

  @Test func tagsAndPins() async throws {
    let client = DevServer.client()
    _ = try await client.createNote(NoteRequest(text: "Tagged #devtest"), idempotencyKey: UUID().uuidString.lowercased())
    let before = try await client.tags()
    #expect(before.recent.contains { $0.tag == "devtest" })
    let pinned = try await client.setPinned(["devtest"], idempotencyKey: UUID().uuidString.lowercased())
    #expect(pinned.pinned == ["devtest"])
    #expect(try await client.setPinned(before.pinned, idempotencyKey: UUID().uuidString.lowercased()).pinned == before.pinned)
  }

  @Test func activityPagesWithItsCursor() async throws {
    let client = DevServer.client()
    _ = try await client.createNote(NoteRequest(text: "For the log #devtest"), idempotencyKey: UUID().uuidString.lowercased())
    let first = try await client.activity(limit: 2)
    #expect(first.items.count == 2)
    let next = try #require(first.next)
    // The cursor holds ":" and "#"; it must survive the query string.
    let second = try await client.activity(before: next, limit: 2)
    #expect(Set(first.items.map(\.id)).isDisjoint(with: second.items.map(\.id)))
    #expect(first.items.contains { $0.via == "token" && $0.client == "Changelog" })
  }

  @Test func errorsDecode() async throws {
    let bad = APIClient(baseURL: DevServer.url, token: "rn_" + String(repeating: "A", count: 43),
                        userAgent: "Changelog/0.1 (dev tests)", session: URLSession(configuration: .ephemeral))
    do {
      _ = try await bad.me()
      Issue.record("an unknown token was let in")
    } catch {
      #expect(error.status == 401)
      #expect(error.signedOut)
      #expect(!error.message.isEmpty)
    }
  }
}
