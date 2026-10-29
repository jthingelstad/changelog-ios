import Foundation
import Testing
@testable import ChangelogKit

@Suite struct ShareInboxTests {
  private func place() -> (inbox: ShareInbox, app: Outbox) {
    let root = FileManager.default.temporaryDirectory.appending(path: "changelog-shares-" + UUID().uuidString, directoryHint: .isDirectory)
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
    #expect(app.url(for: file).map { FileManager.default.fileExists(atPath: $0.path()) } == true)
    #expect((try FileManager.default.contentsOfDirectory(atPath: inbox.folder.path())).filter { $0.hasSuffix(".json") }.isEmpty)
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
}

private extension ShareInbox {
  /// Adopts, then lists what is left in the shared files folder.
  func adoptAfterwards(_ app: Outbox, now: Date) async throws -> [String] {
    await adopt(into: app, now: now)
    return (try? FileManager.default.contentsOfDirectory(atPath: files.path())) ?? []
  }
}
