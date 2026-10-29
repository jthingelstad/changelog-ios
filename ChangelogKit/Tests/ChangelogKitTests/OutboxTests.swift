import Foundation
import Testing
@testable import ChangelogKit

private func receipt(_ id: String) -> NoteReceipt {
  NoteReceipt(note: NoteRef(id: id, date: "2026-10-29", version: "4.5.137", revision: 1, token: "Changelog"), unlocked: nil)
}

/// Remembers what it was asked, and answers from a script of outcomes.
private actor Script {
  var outcomes: [Result<NoteReceipt, APIError>]
  var sent: [OutboxItem] = []
  init(_ outcomes: [Result<NoteReceipt, APIError>]) { self.outcomes = outcomes }
  func next(_ item: OutboxItem) throws(APIError) -> NoteReceipt {
    sent.append(item)
    return try outcomes.removeFirst().get()
  }
}

@Suite struct OutboxTests {
  @Test func sendsOldestFirstAndEmpties() async {
    let outbox = Outbox(file: nil)
    await outbox.enqueue(text: "one")
    await outbox.enqueue(text: "two")
    let script = Script([.success(receipt("a")), .success(receipt("b"))])
    let report = await outbox.flush { item throws(APIError) in try await script.next(item) }
    #expect(report.sent.map(\.item.text) == ["one", "two"])
    #expect(report.stopped == nil)
    #expect(await outbox.waiting.isEmpty)
  }

  @Test func offlineStopsAndKeepsTheOrder() async {
    let outbox = Outbox(file: nil)
    await outbox.enqueue(text: "one")
    await outbox.enqueue(text: "two")
    let offline = APIError(status: 0, code: "network", message: "offline")
    let script = Script([.failure(offline)])
    let report = await outbox.flush { item throws(APIError) in try await script.next(item) }
    #expect(report.stopped == offline)
    #expect(await script.sent.count == 1)
    let waiting = await outbox.waiting
    #expect(waiting.map(\.text) == ["one", "two"])
    #expect(waiting.first?.attempts == 1)
  }

  @Test func aRetryUsesTheSameKey() async {
    let outbox = Outbox(file: nil)
    let item = await outbox.enqueue(text: "one")
    let busy = APIError(status: 409, code: "busy", message: "busy")
    let script = Script([.failure(busy), .success(receipt("a"))])
    _ = await outbox.flush { item throws(APIError) in try await script.next(item) }
    _ = await outbox.flush { item throws(APIError) in try await script.next(item) }
    let keys = await script.sent.map(\.idempotencyKey)
    #expect(keys == [item.idempotencyKey, item.idempotencyKey])
    #expect(await outbox.waiting.isEmpty)
  }

  @Test func aRefusalIsSetAsideAndTheRestGo() async {
    let outbox = Outbox(file: nil)
    await outbox.enqueue(text: "too long")
    await outbox.enqueue(text: "fine")
    let refused = APIError(status: 413, code: "too_large", message: "That note is over 20,000 characters.")
    let script = Script([.failure(refused), .success(receipt("b"))])
    let report = await outbox.flush { item throws(APIError) in try await script.next(item) }
    #expect(report.refused.map(\.text) == ["too long"])
    #expect(report.sent.map(\.item.text) == ["fine"])
    let waiting = await outbox.waiting
    #expect(waiting.map(\.refusal) == ["That note is over 20,000 characters."])

    // Fixed by hand, it goes back in line under a new key.
    let old = waiting[0]
    await outbox.retry(old.id, text: "shorter")
    let again = await outbox.waiting[0]
    #expect(again.refusal == nil)
    #expect(again.idempotencyKey != old.idempotencyKey)
  }

  @Test func signedOutStops() async {
    let outbox = Outbox(file: nil)
    await outbox.enqueue(text: "one")
    let revoked = APIError(status: 401, code: "token_revoked", message: "revoked")
    let script = Script([.failure(revoked)])
    let report = await outbox.flush { item throws(APIError) in try await script.next(item) }
    #expect(report.stopped?.signedOut == true)
    #expect(await outbox.waiting.count == 1)
  }

  @Test func survivesARelaunch() async throws {
    let file = FileManager.default.temporaryDirectory.appending(path: "outbox-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: file) }
    let written = Date(timeIntervalSince1970: 1_793_257_120)
    let first = Outbox(file: file)
    let item = await first.enqueue(text: "typed on the train", writtenAt: written, timeZone: TimeZone(identifier: "America/Chicago")!)
    #expect(item.writtenAt == "2026-10-29T01:58:40-05:00")
    let second = Outbox(file: file)
    #expect(await second.waiting == [item])
  }
}
