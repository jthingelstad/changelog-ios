import Foundation
import Testing
@testable import ChangelogKit

@Suite struct ShareInboxTests {
  private func place() -> (inbox: ShareInbox, app: Outbox) {
    let root = FileManager.default.temporaryDirectory.appending(path: "changelog shares " + UUID().uuidString, directoryHint: .isDirectory)
    let app = Outbox(file: root.appending(path: "app/outbox.json"), files: root.appending(path: "app/files", directoryHint: .isDirectory))
    return (ShareInbox(folder: root.appending(path: "shares", directoryHint: .isDirectory)), app)
  }

  /// A share the extension couldn't send, as it leaves it.
  private func leftOver(_ inbox: ShareInbox) async throws -> (item: OutboxItem, file: QueuedFile) {
    let share = inbox.open()
    let file = QueuedFile(type: "application/pdf", name: "Boarding pass.pdf", size: 9)
    try share.outbox.keep(Data("%PDF-1.7\n".utf8), as: file)
    let item = try await share.outbox.enqueue(.post(NotePost(text: "Flying out #trip", writtenAt: "2026-10-29T07:45:00-05:00", files: [file])))
    inbox.close(share.file, sent: false)
    return (item, file)
  }

  @Test func theAppTakesInWhatTheExtensionLeftUnderTheSameKey() async throws {
    let (inbox, app) = place()
    let (item, file) = try await leftOver(inbox)
    #expect(await inbox.adopt(into: app) == 1)
    let adopted = try #require(await app.waiting.first)
    #expect(adopted.id == item.id && adopted.operation == item.operation)
    // The file moved beside the app's queue; the share is gone.
    #expect(app.url(for: file).map { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) } == true)
    #expect((try FileManager.default.contentsOfDirectory(atPath: inbox.folder.path(percentEncoded: false))).filter { $0.hasSuffix(".json") }.isEmpty)
    // Taking it in again changes nothing.
    #expect(await inbox.adopt(into: app) == 0)
    #expect(await app.waiting.count == 1)
  }

  @Test func aShareTheExtensionIsStillSendingWaits() async throws {
    let (inbox, app) = place()
    let share = inbox.open()
    try await share.outbox.enqueue(.post(NotePost(text: "Mid-send", writtenAt: "2026-10-29T07:45:00-05:00")))
    #expect(await inbox.adopt(into: app) == 0)
    // An extension ended mid-send leaves it; after a while the app takes it.
    #expect(await inbox.adopt(into: app, now: .now.addingTimeInterval(ShareInbox.abandoned + 60)) == 1)
  }

  @Test func aShareThatWentLeavesNothing() async throws {
    let (inbox, app) = place()
    let share = inbox.open()
    try await share.outbox.enqueue(.post(NotePost(text: "Sent", writtenAt: "2026-10-29T07:45:00-05:00")))
    inbox.close(share.file, sent: true)
    #expect(await inbox.adopt(into: app) == 0)
    #expect(await app.waiting.isEmpty)
  }

  @Test func aDraftsFilesStayWhileItsSheetIsOpen() async throws {
    let (inbox, app) = place()
    let share = inbox.open()
    let file = QueuedFile(type: "application/pdf", name: "Menu.pdf", size: 9)
    try share.outbox.keep(Data("%PDF-1.7\n".utf8), as: file)
    inbox.hold([file], for: share.file)
    // Left open past the stray-file window, the draft still has its file.
    let open = try await inbox.adoptAfterwards(app, now: .now.addingTimeInterval(ShareInbox.abandoned + 60))
    #expect(open.contains(file.fileName))
    // A day on, the sheet is taken to be gone, and the file with it.
    let gone = try await inbox.adoptAfterwards(app, now: .now.addingTimeInterval(ShareInbox.draftLife + 60))
    #expect(!gone.contains(file.fileName))
  }

  @Test func committingReleasesTheDraft() async throws {
    let (inbox, _) = place()
    let share = inbox.open()
    inbox.hold([], for: share.file)
    try await share.outbox.enqueue(.post(NotePost(text: "Saved", writtenAt: "2026-10-29T07:45:00-05:00")))
    inbox.close(share.file, sent: false)
    let left = try FileManager.default.contentsOfDirectory(atPath: inbox.folder.path(percentEncoded: false))
    #expect(left.filter { $0.hasSuffix(".draft") }.isEmpty && left.contains { $0.hasSuffix(".json") })
  }

  @Test func strayFilesGoOnceOld() async throws {
    let (inbox, app) = place()
    let (_, held) = try await leftOver(inbox)
    let stray = QueuedFile(type: "image/png", name: "x.png", size: 1)
    try FileManager.default.createDirectory(at: inbox.files, withIntermediateDirectories: true)
    try Data("x".utf8).write(to: inbox.files.appending(path: stray.fileName))
    // Not old yet: an extension may still be writing it.
    let young = try await inbox.adoptAfterwards(app, now: .now)
    #expect(young.contains(stray.fileName))
    let old = try await inbox.adoptAfterwards(app, now: .now.addingTimeInterval(ShareInbox.abandoned + 60))
    #expect(!old.contains(stray.fileName) && !old.contains(held.fileName))
  }

  private func shares(_ inbox: ShareInbox) -> [String] {
    (try? FileManager.default.contentsOfDirectory(atPath: inbox.folder.path(percentEncoded: false))) ?? []
  }

  /// A share its extension closed again after the app took it in (suspended
  /// mid-send, then woken) is never taken in twice, even once its note went
  /// and the app started again.
  @Test func aShareTakenInBeforeIsNotTakenInAgain() async throws {
    let (inbox, app) = place()
    let (item, _) = try await leftOver(inbox)
    #expect(await inbox.adopt(into: app) == 1)
    let filed = NoteReceipt(note: NoteRef(id: "t-1", date: "2026-10-29", version: "4.5.137", revision: "r"), unlocked: nil)
    let report = await app.flush(prepare: { item, _ throws(APIError) in
      guard case .post(var post) = item.operation else { return item }
      for i in post.files.indices { post.files[i].upload = String(repeating: "a", count: 32) }
      var ready = item
      ready.operation = .post(post)
      return ready
    }) { _ throws(APIError) in .filed(filed) }
    #expect(report.filed == [filed])
    // The woken extension's copy, closed again.
    try JSONEncoder().encode([item]).write(to: inbox.folder.appending(path: UUID().uuidString.lowercased() + ".json"))
    let relaunched = Outbox(file: app.filesFolder!.deletingLastPathComponent().appending(path: "outbox.json"),
                            files: app.filesFolder)
    #expect(await inbox.adopt(into: relaunched) == 0)
    #expect(await relaunched.waiting.isEmpty)
    #expect(shares(inbox).filter { $0.hasSuffix(".json") }.isEmpty)
  }

  /// Once the app has taken in a share left mid-send, its extension, woken,
  /// writes and sends nothing more: its files posted, it stands down rather
  /// than send them under the key the app's copy holds.
  @Test func anExtensionWokenAfterTheAppTookItsShareStandsDown() async throws {
    let (inbox, app) = place()
    let share = inbox.open()
    let file = QueuedFile(type: "application/pdf", name: "Boarding pass.pdf", size: 9)
    try share.outbox.keep(Data("%PDF-1.7\n".utf8), as: file)
    try await share.outbox.enqueue(.post(NotePost(text: "Flying out #trip", writtenAt: "2026-10-29T07:45:00-05:00", files: [file])))
    #expect(await inbox.adopt(into: app, now: .now.addingTimeInterval(ShareInbox.abandoned + 60)) == 1)
    let report = await share.outbox.flush(prepare: { item, _ throws(APIError) in
      guard case .post(var post) = item.operation else { return item }
      post.files[0].upload = String(repeating: "b", count: 32)
      var ready = item
      ready.operation = .post(post)
      return ready
    }) { _ throws(APIError) in
      Issue.record("the extension sent a share the app holds")
      return .deleted
    }
    #expect(report.stopped?.code == "not_kept" && report.sent.isEmpty)
    inbox.close(share.file, sent: false)
    #expect(shares(inbox).filter { $0.hasSuffix(".json") }.isEmpty)
    #expect(await inbox.adopt(into: app) == 0)
    #expect(await app.waiting.count == 1)
  }

  /// A share this build can't read is moved aside, never removed, and the
  /// files it names stay; once a build reads it, it is taken in.
  @Test func aShareItCantReadIsSetAsideWithItsFiles() async throws {
    let (inbox, app) = place()
    let photo = QueuedFile(type: "image/jpeg", name: "Photo 1.jpg", size: 1)
    let other = QueuedFile(type: "image/jpeg", name: "Photo 2.jpg", size: 1)
    try FileManager.default.createDirectory(at: inbox.files, withIntermediateDirectories: true)
    for f in [photo, other] { try Data("x".utf8).write(to: inbox.files.appending(path: f.fileName)) }
    let newer = """
      [{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","queuedAt":783000000,"attempts":0,
        "operation":{"video":{"text":"one","files":[{"id":"\(photo.id.uuidString)","type":"image/jpeg","name":"Photo 1.jpg","size":1}]}}}]
      """
    try Data(newer.utf8).write(to: inbox.folder.appending(path: "a.json"))
    let left = try await inbox.adoptAfterwards(app, now: .now.addingTimeInterval(ShareInbox.abandoned + 60))
    #expect(left.contains(photo.fileName) && !left.contains(other.fileName))
    let aside = shares(inbox).filter { $0.hasSuffix(".unreadable") }
    #expect(aside.count == 1 && aside[0].hasPrefix("a.json.") && !shares(inbox).contains("a.json"))
    #expect(try Data(contentsOf: inbox.folder.appending(path: aside[0])) == Data(newer.utf8))
    // Still unread, it stays as it is.
    #expect(await inbox.adopt(into: app) == 0)
    #expect(shares(inbox).filter { $0.hasSuffix(".unreadable") } == aside)
    // Written as this build reads it (a newer build would), it comes in.
    let item = OutboxItem(id: UUID(), operation: .post(NotePost(text: "one", writtenAt: "2026-10-29T07:45:00-05:00", files: [photo])),
                          queuedAt: .now, attempts: 0, refusal: nil)
    try JSONEncoder().encode([item]).write(to: inbox.folder.appending(path: aside[0]))
    #expect(await inbox.adopt(into: app) == 1)
    #expect(shares(inbox).filter { $0.hasSuffix(".unreadable") }.isEmpty)
    #expect(app.url(for: photo).map { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) } == true)
  }
}

private extension ShareInbox {
  /// Adopts, then lists what is left in the shared files folder.
  func adoptAfterwards(_ app: Outbox, now: Date) async throws -> [String] {
    await adopt(into: app, now: now)
    return (try? FileManager.default.contentsOfDirectory(atPath: files.path(percentEncoded: false))) ?? []
  }
}
