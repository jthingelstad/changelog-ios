import Foundation
import Testing
@testable import ChangelogKit

private func receipt(_ id: String) -> NoteReceipt {
  NoteReceipt(note: NoteRef(id: id, date: "2026-10-29", version: "4.5.137", revision: "r-" + id, token: "Changelog"), unlocked: nil)
}

/// Remembers what it was asked, and answers from a script of outcomes.
private actor Script {
  var outcomes: [Result<OutboxResult, APIError>]
  var sent: [OutboxItem] = []
  init(_ outcomes: [Result<OutboxResult, APIError>]) { self.outcomes = outcomes }
  func next(_ item: OutboxItem) throws(APIError) -> OutboxResult {
    sent.append(item)
    return try outcomes.removeFirst().get()
  }
}

@Suite struct OutboxTests {
  @Test func sendsOldestFirstAndEmpties() async throws {
    let outbox = Outbox(file: nil)
    try await outbox.enqueue(text: "one")
    try await outbox.enqueue(text: "two")
    let script = Script([.success(.filed(receipt("a"))), .success(.filed(receipt("b")))])
    let report = await outbox.flush { item throws(APIError) in try await script.next(item) }
    #expect(report.sent.map(\.item.text) == ["one", "two"])
    #expect(report.filed.map(\.note.id) == ["a", "b"])
    #expect(report.stopped == nil)
    #expect(await outbox.waiting.isEmpty)
  }

  @Test func offlineStopsAndKeepsTheOrder() async throws {
    let outbox = Outbox(file: nil)
    try await outbox.enqueue(text: "one")
    try await outbox.enqueue(text: "two")
    let offline = APIError(status: 0, code: "network", message: "offline")
    let script = Script([.failure(offline)])
    let report = await outbox.flush { item throws(APIError) in try await script.next(item) }
    #expect(report.stopped == offline)
    #expect(await script.sent.count == 1)
    let waiting = await outbox.waiting
    #expect(waiting.map(\.text) == ["one", "two"])
    #expect(waiting.first?.attempts == 1)
  }

  @Test func aRetryUsesTheSameKey() async throws {
    let outbox = Outbox(file: nil)
    let item = try await outbox.enqueue(text: "one")
    let busy = APIError(status: 409, code: "busy", message: "busy")
    let script = Script([.failure(busy), .success(.filed(receipt("a")))])
    _ = await outbox.flush { item throws(APIError) in try await script.next(item) }
    _ = await outbox.flush { item throws(APIError) in try await script.next(item) }
    let keys = await script.sent.map(\.idempotencyKey)
    #expect(keys == [item.idempotencyKey, item.idempotencyKey])
    #expect(await outbox.waiting.isEmpty)
  }

  /// An edit whose answer was lost goes again with its key and the revision
  /// it read, so Release Notes replays the edit rather than refusing it.
  @Test func anEditKeepsItsKeyAndRevision() async throws {
    let outbox = Outbox(file: nil)
    let edit = try await outbox.enqueue(.edit(date: "2026-10-29", id: "t-1", text: "better", revision: "r-1"))
    let offline = APIError(status: 0, code: "network", message: "offline")
    let ref = NoteRef(id: "t-1", date: "2026-10-29", version: "4.5.137", revision: "r-2", token: "Changelog")
    let script = Script([.failure(offline), .success(.edited(ref))])
    _ = await outbox.flush { item throws(APIError) in try await script.next(item) }
    let report = await outbox.flush { item throws(APIError) in try await script.next(item) }
    #expect(report.sent.map(\.result) == [.edited(ref)])
    let sent = await script.sent
    #expect(sent.map(\.idempotencyKey) == [edit.idempotencyKey, edit.idempotencyKey])
    #expect(sent.map(\.operation) == [edit.operation, edit.operation])
  }

  @Test func aRefusalIsSetAsideAndTheRestGo() async throws {
    let outbox = Outbox(file: nil)
    try await outbox.enqueue(text: "too long")
    try await outbox.enqueue(text: "fine")
    let refused = APIError(status: 413, code: "too_large", message: "That note is over 20,000 characters.")
    let script = Script([.failure(refused), .success(.filed(receipt("b")))])
    let report = await outbox.flush { item throws(APIError) in try await script.next(item) }
    #expect(report.refused.map(\.text) == ["too long"])
    #expect(report.sent.map(\.item.text) == ["fine"])
    let waiting = await outbox.waiting
    #expect(waiting.map(\.refusal) == ["That note is over 20,000 characters."])

    // Fixed by hand, it goes back in line under a new key.
    let old = waiting[0]
    try await outbox.retry(old.id, text: "shorter")
    let again = await outbox.waiting[0]
    #expect(again.refusal == nil)
    #expect(again.text == "shorter")
    #expect(again.idempotencyKey != old.idempotencyKey)
  }

  @Test func signedOutStops() async throws {
    let outbox = Outbox(file: nil)
    try await outbox.enqueue(text: "one")
    let revoked = APIError(status: 401, code: "token_revoked", message: "revoked")
    let script = Script([.failure(revoked)])
    let report = await outbox.flush { item throws(APIError) in try await script.next(item) }
    #expect(report.stopped?.signedOut == true)
    #expect(await outbox.waiting.count == 1)
  }

  /// A note committed while another is on its way joins the run under way,
  /// rather than waiting for the next commit or refresh.
  @Test func aCommitDuringASendJoinsTheRun() async throws {
    let outbox = Outbox(file: nil)
    try await outbox.enqueue(text: "one")
    let script = Script([.success(.filed(receipt("a"))), .success(.filed(receipt("b")))])
    let report = await outbox.flush { item throws(APIError) in
      if item.text == "one" {
        _ = try? await outbox.enqueue(text: "two")
        let second = await outbox.flush { item throws(APIError) in try await script.next(item) }
        #expect(second == FlushReport())
      }
      return try await script.next(item)
    }
    #expect(report.sent.map(\.item.text) == ["one", "two"])
    #expect(await outbox.waiting.isEmpty)
  }

  @Test func survivesARelaunch() async throws {
    let file = FileManager.default.temporaryDirectory.appending(path: "outbox-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: file) }
    let written = Date(timeIntervalSince1970: 1_793_257_120)
    let first = Outbox(file: file)
    let item = try await first.enqueue(text: "typed on the train", writtenAt: written, timeZone: TimeZone(identifier: "America/Chicago")!)
    #expect(item.operation == .note(text: "typed on the train", date: nil, writtenAt: "2026-10-29T01:58:40-05:00"))
    let pins = try await first.enqueue(.pins(["running", "trip"]))
    let second = Outbox(file: file)
    #expect(await second.waiting == [item, pins])
  }

  /// When the phone can't keep the queue, the write is refused at once, so
  /// the app keeps the words in the box instead of losing them.
  @Test func aQueueThatCantBeSavedRefusesTheNote() async throws {
    let blocker = FileManager.default.temporaryDirectory.appending(path: "outbox-blocker-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: blocker) }
    try Data().write(to: blocker)
    // The queue's folder is a file, so nothing can be written under it.
    let outbox = Outbox(file: blocker.appending(path: "outbox.json"))
    await #expect(throws: OutboxNotKept.self) { try await outbox.enqueue(text: "one") }
    #expect(await outbox.waiting.isEmpty)
  }
}
