import Foundation
import Testing
@testable import ChangelogKit

@Suite struct QuickNoteTests {
  private func place() -> (inbox: ShareInbox, app: Outbox) {
    let root = FileManager.default.temporaryDirectory.appending(path: "changelog quick " + UUID().uuidString, directoryHint: .isDirectory)
    let app = Outbox(file: root.appending(path: "app/outbox.json"), files: root.appending(path: "app/files", directoryHint: .isDirectory))
    return (ShareInbox(folder: root.appending(path: "shares", directoryHint: .isDirectory)), app)
  }

  private func queued(_ inbox: ShareInbox) async throws -> (share: (outbox: Outbox, file: URL), item: OutboxItem) {
    let share = inbox.open()
    let item = try await share.outbox.enqueue(.post(NotePost(text: "Fixed the gate #house", writtenAt: "2026-10-28T07:45:00-05:00")))
    return (share, item)
  }

  private func names(_ inbox: ShareInbox) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: inbox.folder.path(percentEncoded: false))) ?? []).filter { $0.hasSuffix(".json") }
  }

  @Test func sentInTimeLeavesNothingForTheApp() async throws {
    StubProtocol.set("quick-filed.test", .init(status: 201, body: """
      {"note":{"id":"t-3f9c","date":"2026-10-28","version":"4.5.136","revision":"9c1e5b0a2f7d4e3c8b6a1f0e","token":"Changelog"}}
      """))
    let (inbox, app) = place()
    let (share, item) = try await queued(inbox)
    let outcome = await QuickNote.send(share, from: inbox, with: stubbedClient("quick-filed.test"), within: .seconds(10))
    guard case .filed(let receipt) = outcome else {
      Issue.record("expected filed, got \(outcome)")
      return
    }
    #expect(QuickNote.said(outcome) == "Filed in 4.5.136.")
    #expect(receipt.note.id == "t-3f9c")
    #expect(names(inbox).isEmpty)
    #expect(await inbox.adopt(into: app) == 0)
    let request = try #require(StubProtocol.requests("quick-filed.test").first)
    #expect(request.value(forHTTPHeaderField: "Idempotency-Key") == item.idempotencyKey)
  }

  @Test func offlineItWaitsForTheAppUnderTheSameKey() async throws {
    // No answer set for this host: the stub fails as if offline.
    let (inbox, app) = place()
    let (share, item) = try await queued(inbox)
    let outcome = await QuickNote.send(share, from: inbox, with: stubbedClient("quick-offline.test"), within: .seconds(10))
    #expect(outcome == .waiting)
    #expect(QuickNote.said(outcome) == "Saved. Changelog sends it when it can.")
    #expect(await inbox.adopt(into: app) == 1)
    #expect(await app.waiting.first?.id == item.id)
  }

  @Test func signedOutItIsLeftForTheApp() async throws {
    let (inbox, app) = place()
    let (share, item) = try await queued(inbox)
    let outcome = await QuickNote.send(share, from: inbox, with: nil, within: .seconds(10))
    #expect(outcome == .noToken)
    #expect(QuickNote.said(outcome) == "Saved. Open Changelog to send it.")
    #expect(await inbox.adopt(into: app) == 1)
    #expect(await app.waiting.first?.id == item.id)
  }

  @Test func aRevokedTokenSaysToSignInAgain() async throws {
    StubProtocol.set("quick-revoked.test", .init(status: 401, body: #"{"error":{"code":"unauthorized","message":"That token was revoked."}}"#))
    let (inbox, app) = place()
    let (share, _) = try await queued(inbox)
    let outcome = await QuickNote.send(share, from: inbox, with: stubbedClient("quick-revoked.test"), within: .seconds(10))
    #expect(outcome == .signedOut)
    #expect(await inbox.adopt(into: app) == 1)
  }

  /// Filed, in an answer this build can't read: it says so, and leaves
  /// nothing for the app to send again.
  @Test func filedInAnAnswerItCantReadSaysFiled() async throws {
    StubProtocol.set("queue-quick-unread.test", .init(status: 201, body: #"{"receipt":{"shape":"from a newer server"}}"#))
    let (inbox, app) = place()
    let (share, _) = try await queued(inbox)
    let outcome = await QuickNote.send(share, from: inbox, with: stubbedClient("queue-quick-unread.test"), within: .seconds(10))
    #expect(outcome == .sent)
    #expect(QuickNote.said(outcome) == "Filed.")
    #expect(names(inbox).isEmpty)
    #expect(await inbox.adopt(into: app) == 0)
  }

  @Test func whatItSaysNeverHasTheWords() {
    let receipt = NoteReceipt(note: NoteRef(id: "t-1", date: "2026-10-28", version: "4.5.136", revision: "r"),
                              unlocked: [Unlocked(key: "api", name: "API release")])
    for outcome: QuickNote.Outcome in [.filed(receipt), .refused("That note is too long."), .signedOut, .waiting, .noToken] {
      #expect(!QuickNote.said(outcome).contains("gate"))
    }
    #expect(QuickNote.said(.filed(receipt)) == "Unlocked: API release")
  }

  @Test func theStickyTagGoesOnTheEnd() {
    #expect(QuickNote.words("  Fixed the gate\n", sticky: "house") == "Fixed the gate #house")
    #expect(QuickNote.words("Fixed the gate #house", sticky: "house") == "Fixed the gate #house")
    #expect(QuickNote.words("Fixed the gate", sticky: nil) == "Fixed the gate")
  }
}
