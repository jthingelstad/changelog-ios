import Foundation
import Testing
@testable import ChangelogKit

/// Whose notes go (API 1.4.0, Jamie's calls of 2026-10-30): every queued
/// write knows the account it was written under, a write of another account
/// (or of none known) is held until the owner sends it to this one or
/// deletes it, an earlier build's notes are stamped with the token still
/// signed in, and Today's "mine" is the token's id.
@Suite struct AccountTests {
  private static let mine = "acct_" + String(repeating: "a", count: 32)
  private static let other = "acct_" + String(repeating: "b", count: 32)

  private static func receipt(_ id: String) -> NoteReceipt {
    NoteReceipt(note: NoteRef(id: id, date: "2026-10-30", version: "4.5.138", revision: "r-" + id, token: "Changelog"), unlocked: nil)
  }

  private static func folder(_ name: String) -> URL {
    FileManager.default.temporaryDirectory.appending(path: "changelog \(name) " + UUID().uuidString, directoryHint: .isDirectory)
  }

  /// Records what was sent, answering each as filed.
  private actor Sent {
    var items: [OutboxItem] = []
    var prepared: [OutboxItem] = []
    func send(_ item: OutboxItem) -> OutboxResult {
      items.append(item)
      return .filed(AccountTests.receipt("t-\(items.count)"))
    }
    func prepare(_ item: OutboxItem) -> OutboxItem {
      prepared.append(item)
      guard case .post(var post) = item.operation else { return item }
      for i in post.files.indices { post.files[i].upload = "up-\(prepared.count)-\(i)" }
      var ready = item
      ready.operation = .post(post)
      return ready
    }
  }

  // MARK: Holding

  @Test func anotherAccountsNotesAndUnknownOnesAreHeld() async throws {
    let outbox = Outbox(file: nil)
    try await outbox.enqueue(text: "theirs", account: Self.other)
    try await outbox.enqueue(text: "unknown")
    try await outbox.enqueue(text: "mine", account: Self.mine)
    try await outbox.enqueue(.pins(["house"]), account: Self.other)
    let sent = Sent()
    let report = await outbox.flush(for: .account(Self.mine)) { item throws(APIError) in await sent.send(item) }
    #expect(report.sent.map(\.item.text) == ["mine"])
    #expect(report.stopped == nil && report.refused.isEmpty)
    let waiting = await outbox.waiting
    #expect(waiting.map(\.text) == ["theirs", "unknown", nil])
    #expect(waiting.allSatisfy { $0.isHeld(for: .account(Self.mine)) })
    // Passed over, not tried: nothing says it was sent or waits on a connection.
    #expect(waiting.allSatisfy { $0.attempts == 0 && $0.held == nil && $0.refusal == nil })
  }

  @Test func aHeldNoteNeverTakesAWaitReason() async throws {
    let outbox = Outbox(file: nil)
    try await outbox.enqueue(text: "theirs", account: Self.other)
    try await outbox.enqueue(text: "mine", account: Self.mine)
    let offline = APIError(status: 0, code: "network", message: "offline")
    _ = await outbox.flush(for: .account(Self.mine)) { _ throws(APIError) in throw offline }
    let waiting = await outbox.waiting
    #expect(waiting.map(\.held) == [nil, "Waiting for a connection"])
  }

  @Test func signingBackInToItsOwnAccountSendsItNormally() async throws {
    let outbox = Outbox(file: nil)
    let theirs = try await outbox.enqueue(text: "theirs", account: Self.other)
    let sent = Sent()
    _ = await outbox.flush(for: .account(Self.mine)) { item throws(APIError) in await sent.send(item) }
    #expect(await sent.items.isEmpty)
    let report = await outbox.flush(for: .account(Self.other)) { item throws(APIError) in await sent.send(item) }
    #expect(report.sent.map(\.item.idempotencyKey) == [theirs.idempotencyKey])
    #expect(await outbox.waiting.isEmpty)
  }

  /// A share's own queue, and a server before 1.4.0, which names no account.
  @Test func anyoneSendsEverything() async throws {
    let outbox = Outbox(file: nil)
    try await outbox.enqueue(text: "theirs", account: Self.other)
    try await outbox.enqueue(text: "unknown")
    let sent = Sent()
    let report = await outbox.flush { item throws(APIError) in await sent.send(item) }
    #expect(report.sent.count == 2)
    #expect(!OutboxItem(id: UUID(), operation: .pins([]), queuedAt: .now, attempts: 0, refusal: nil).isHeld(for: .anyone))
  }

  // MARK: An earlier build's notes

  @Test func stampingTakesOnlyTheUnknownAndIsKept() async throws {
    let root = Self.folder("stamp")
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appending(path: "Application Support/outbox.json")
    let outbox = Outbox(file: file)
    try await outbox.enqueue(text: "before 1.4.0")
    try await outbox.enqueue(text: "theirs", account: Self.other)
    try await outbox.enqueue(.delete(date: "2026-10-30", id: "t-1"))
    #expect(try await outbox.stamp(unknownWith: Self.mine) == 2)
    #expect(try await outbox.stamp(unknownWith: Self.other) == 0)
    let relaunched = await Outbox(file: file).waiting
    #expect(relaunched.map(\.account) == [Self.mine, Self.other, Self.mine])
  }

  /// A queue an earlier build wrote has no `account` in it at all.
  @Test func aQueueFromAnEarlierBuildReadsWithNoAccount() throws {
    let saved = """
      [{"id":"9C1E5B0A-2F7D-4E3C-8B6A-1F0E2D3C4B5A","operation":{"note":{"text":"Offline before the update",
        "writtenAt":"2026-10-29T22:10:00-05:00"}},"queuedAt":783000000,"attempts":1}]
      """
    let items = try JSONDecoder().decode([OutboxItem].self, from: Data(saved.utf8))
    #expect(items.first?.account == nil)
    #expect(items.first?.isHeld(for: .account(Self.mine)) == true)
    var stamped = try #require(items.first)
    stamped.account = Self.mine
    let again = try JSONDecoder().decode(OutboxItem.self, from: JSONEncoder().encode(stamped))
    #expect(again.account == Self.mine && !again.isHeld(for: .account(Self.mine)))
  }

  // MARK: Send to this account

  /// A note prepared under the other account goes to this one under its own
  /// key, its files posted again; its place, only names, stays.
  @Test func sendingToThisAccountPreparesItsFilesAgainUnderTheSameKey() async throws {
    let root = Self.folder("move")
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appending(path: "Application Support/outbox.json")
    let outbox = Outbox(file: file)
    var photo = QueuedFile(type: "image/jpeg", name: "Photo 1.jpg", size: 4)
    try outbox.keep(Data("jpeg".utf8), as: photo)
    photo.upload = "other-accounts-upload"
    let place = DevicePlace(name: "Minneapolis", region: "Minnesota", country: "United States", tz: "America/Chicago",
                            district: "Loring Park", venue: "Corner Café", lat: 44.97, lon: -93.28, accuracyM: 30, from: "device")
    let spot = Spot(lat: 44.97, lon: -93.28, accuracyM: 30)
    let held = try await outbox.enqueue(.post(NotePost(text: "Lunch", writtenAt: "2026-10-30T12:10:00-05:00", files: [photo],
                                                       spot: spot, place: place)), account: Self.other)
    let sent = Sent()
    let prepare: Outbox.Preparer = { item, _ throws(APIError) in await sent.prepare(item) }
    _ = await outbox.flush(for: .account(Self.mine), prepare: prepare) { item throws(APIError) in await sent.send(item) }
    #expect(await sent.items.isEmpty, "nothing held goes without the owner's word")
    #expect(await sent.prepared.isEmpty, "nor is it prepared")

    try await outbox.move(held.id, to: Self.mine)
    let moved = try #require(await Outbox(file: file).waiting.first, "the move is on disk")
    #expect(moved.id == held.id && moved.account == Self.mine)
    guard case .post(let post) = moved.operation else { Issue.record("not a post"); return }
    #expect(post.files.map(\.upload) == [nil])
    #expect(post.place == place && post.spot == spot)

    let report = await outbox.flush(for: .account(Self.mine), prepare: prepare) { item throws(APIError) in await sent.send(item) }
    #expect(report.filed.count == 1)
    let went = try #require(await sent.items.first)
    #expect(went.idempotencyKey == held.idempotencyKey)
    #expect(await sent.prepared.count == 1)
    guard case .post(let sentPost) = went.operation else { Issue.record("not a post"); return }
    #expect(sentPost.request.uploads?.map(\.upload) == ["up-1-0"])
    #expect(sentPost.request.place?.venue == "Corner Café")
  }

  @Test func anEditOrADeleteOfAnotherAccountsNoteNeverMoves() async throws {
    let outbox = Outbox(file: nil)
    let edit = try await outbox.enqueue(.edit(date: "2026-10-30", id: "t-1", text: "better", revision: "r-1"), account: Self.other)
    let delete = try await outbox.enqueue(.delete(date: "2026-10-30", id: "t-2"), account: Self.other)
    let pins = try await outbox.enqueue(.pins(["house"]), account: Self.other)
    #expect(!edit.canMove && !delete.canMove && pins.canMove)
    for item in [edit, delete, pins] { try await outbox.move(item.id, to: Self.mine) }
    let waiting = await outbox.waiting
    #expect(waiting.map(\.account) == [Self.other, Self.other, Self.mine])
    let sent = Sent()
    let report = await outbox.flush(for: .account(Self.mine)) { item throws(APIError) in await sent.send(item) }
    #expect(report.sent.map(\.item.id) == [pins.id])
  }

  @Test func aHeldNoteCanBeDeleted() async throws {
    let outbox = Outbox(file: nil)
    let held = try await outbox.enqueue(text: "theirs", account: Self.other)
    await outbox.discard(held.id)
    #expect(await outbox.waiting.isEmpty)
  }

  // MARK: Shares

  @Test func aShareKeepsTheAccountItWasStampedWith() async throws {
    let root = Self.folder("shares")
    defer { try? FileManager.default.removeItem(at: root) }
    let inbox = ShareInbox(folder: root.appending(path: "shares", directoryHint: .isDirectory))
    let app = Outbox(file: root.appending(path: "app/outbox.json"))
    let share = inbox.open()
    try await share.outbox.enqueue(.post(NotePost(text: "Shared", writtenAt: "2026-10-30T07:45:00-05:00")), account: Self.other)
    inbox.close(share.file, sent: false)
    #expect(await inbox.adopt(into: app) == 1)
    #expect(await app.waiting.first?.account == Self.other)
  }

  // MARK: Decoding

  @Test func meAndActivityDecodeTheIdsAndDoWithoutThem() throws {
    let decoder = APIClient.decoder
    let new = try decoder.decode(Me.self, from: Data("""
      {"account":"\(Self.mine)","today":"2026-10-30","version":"4.5.138","tz":"America/Chicago","send_time":"06:30",
       "wrote_today":false,"streak":1,"paused_until":null,"status":"active","show_badges":true,"days":[],
       "token":{"id":"0f8e2c4a9b7d4e1f8a6c3b5d7e9f1a2b","name":"Changelog","scopes":["notes:write"],"expires_at":null},
       "api_version":"1.4.0"}
      """.utf8))
    #expect(new.account == Self.mine)
    #expect(new.token.id == "0f8e2c4a9b7d4e1f8a6c3b5d7e9f1a2b")
    let old = try decoder.decode(Me.self, from: Data("""
      {"today":"2026-10-30","version":"4.5.138","tz":"America/Chicago","send_time":"06:30","wrote_today":false,
       "streak":1,"paused_until":null,"status":"active","show_badges":true,"days":[],
       "token":{"name":"Changelog","scopes":["notes:write"],"expires_at":null},"api_version":"1.3.0"}
      """.utf8))
    #expect(old.account == nil && old.token.id == nil)
    let rows = try decoder.decode(ActivityPage.self, from: Data("""
      {"items":[{"id":"a","at":"2026-10-30T14:00:00.000Z","kind":"note.added","via":"token","token":"Changelog",
                 "token_id":"0f8e2c4a9b7d4e1f8a6c3b5d7e9f1a2b","day":"2026-10-30","note":"t-1"},
                {"id":"b","at":"2026-10-29T14:00:00.000Z","kind":"note.added","via":"token","token":"Changelog",
                 "day":"2026-10-29","note":"t-0"}],"next":null}
      """.utf8)).items
    #expect(rows.map(\.tokenId) == ["0f8e2c4a9b7d4e1f8a6c3b5d7e9f1a2b", nil])
  }

  // MARK: Mine

  private static func row(_ note: String, token: String? = "Changelog", id: String? = nil, via: String = "token",
                          kind: String = "note.added") -> ActivityItem {
    ActivityItem(id: "row-" + note, at: "2026-10-30T14:00:00.000Z", kind: kind, via: via, token: token, day: "2026-10-30",
                 note: note, tokenId: id)
  }

  @Test func mineIsTheTokensIdAndItsNameOnlyForOlderRows() {
    let me = TokenInfo(name: "Changelog", scopes: ["notes:write"], expiresAt: nil, id: "id-now")
    #expect(TodayWords.isMine(Self.row("t-1", id: "id-now"), token: me))
    // An earlier token of the same name (signed out, then in again) is not this one.
    #expect(!TodayWords.isMine(Self.row("t-2", id: "id-before"), token: me))
    // A row from before 1.4.0 has no id: its name decides.
    #expect(TodayWords.isMine(Self.row("t-3"), token: me))
    #expect(!TodayWords.isMine(Self.row("t-4", token: "Terminal"), token: me))
    #expect(!TodayWords.isMine(Self.row("t-5", id: "id-now", via: "web"), token: me))
    #expect(!TodayWords.isMine(Self.row("t-6", id: "id-now", kind: "note.edited"), token: me))
    // A server that names no token id: a row with one is never taken by name.
    let older = TokenInfo(name: "Changelog", scopes: ["notes:write"], expiresAt: nil)
    #expect(!TodayWords.isMine(Self.row("t-7", id: "id-now"), token: older))
    #expect(TodayWords.isMine(Self.row("t-8"), token: older))
  }

  @Test func todaysWordsAreReadOnlyForMine() {
    let me = TokenInfo(name: "Changelog", scopes: ["notes:write"], expiresAt: nil, id: "id-now")
    let rows = [Self.row("t-1", id: "id-now"), Self.row("t-2", id: "id-before"), Self.row("t-3")]
    #expect(TodayWords.notes(in: rows, by: me) == [TodayWords.Note(date: "2026-10-30", id: "t-1"),
                                                  TodayWords.Note(date: "2026-10-30", id: "t-3")])
  }
}
