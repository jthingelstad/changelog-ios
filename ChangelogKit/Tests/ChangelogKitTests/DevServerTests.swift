import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
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

  /// A moment files to its own day: `date` an earlier day, `written_at`
  /// now. A day before the birthday is refused, and the Outbox files that
  /// note to the day it was written instead.
  @Test func aMomentFilesToItsOwnDay() async throws {
    let client = DevServer.client(), outbox = Outbox(file: nil)
    let me = try await client.me()
    let zone = try #require(TimeZone(identifier: me.tz))
    let earlier = try #require(Moment.day(of: Date.now.addingTimeInterval(-3 * 86400), in: zone))
    try await outbox.enqueue(text: "Dev test, a moment three days back #devtest", date: earlier)
    try await outbox.enqueue(text: "Dev test, before the birthday #devtest", date: "1900-01-01")
    let report = await outbox.flush { (item) async throws(APIError) -> OutboxResult in try await client.perform(item) }
    #expect(report.stopped == nil)
    #expect(report.refused.isEmpty)
    #expect(report.filed.map(\.note.date) == [earlier, me.today])
    #expect(report.filed.first?.note.version != me.version)
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

  @Test func remindersDecode() async throws {
    let client = DevServer.client()
    guard try await client.me().token.scopes.contains("upcoming") else { return }
    let reminders = try await client.reminders()
    #expect(reminders.from <= reminders.through)
    for day in reminders.days {
      #expect((try? Date(day.sendAt, strategy: .iso8601)) != nil)
      #expect(!day.reminders.isEmpty)
    }
  }

  /// A note with a photo and no words, its spot named as it sends; then one
  /// with a business picked from Here; then one whose upload is gone, which
  /// is made again once under a new key.
  @Test func filesAndPlaces() async throws {
    let client = DevServer.client()
    guard try await client.me().token.scopes.contains("media:write") else { return }
    let folder = FileManager.default.temporaryDirectory.appending(path: "changelog dev " + UUID().uuidString, directoryHint: .isDirectory)
    let outbox = Outbox(file: nil, files: folder)
    let prepare: Outbox.Preparer = { item, folder throws(APIError) in try await client.prepare(item, files: folder) }
    let send: Outbox.Sender = { item throws(APIError) in try await client.perform(item) }

    let photo = QueuedFile(type: "image/png", name: "Photo 1.png", size: 0)
    let png = Self.png()
    var sized = photo
    sized.size = png.count
    try outbox.keep(png, as: sized)
    try await outbox.enqueue(.post(NotePost(text: "", writtenAt: Timestamp.string(.now), files: [sized],
                                            spot: Spot(lat: 44.98, lon: -93.26, accuracyM: 30))))
    var report = await outbox.flush(prepare: prepare, send)
    #expect(report.stopped == nil && report.refused.isEmpty)
    let first = try #require(report.filed.first)
    #expect(first.note.files == 1)
    #expect(outbox.url(for: sized).map { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) } == false)

    let here = try await client.here(Spot(lat: 44.98, lon: -93.26, accuracyM: 30))
    #expect(here.place.from == "device")
    var place = here.place
    place.venue = try #require(here.nearby.first?.name)
    try await outbox.enqueue(.post(NotePost(text: "Lunch #devtest", writtenAt: Timestamp.string(.now),
                                            spot: Spot(lat: 44.98, lon: -93.26), place: place)))
    report = await outbox.flush(prepare: prepare, send)
    #expect(report.filed.count == 1 && report.refused.isEmpty)

    var stale = QueuedFile(type: "image/png", name: "Photo 2.png", size: png.count, upload: String(repeating: "0", count: 32))
    try outbox.keep(png, as: stale)
    stale.type = "image/png"
    let queued = try await outbox.enqueue(.post(NotePost(text: "Gone upload #devtest", writtenAt: Timestamp.string(.now), files: [stale])))
    report = await outbox.flush(prepare: prepare, send)
    #expect(report.refused.isEmpty, "the uploads refusal should be made again, not set aside")
    let remade = try #require(report.sent.first?.item)
    #expect(remade.idempotencyKey != queued.idempotencyKey)
    #expect(report.filed.first?.note.files == 1)
  }

  static func png() -> Data {
    let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: 0.9, green: 0.5, blue: 0.1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
    let out = NSMutableData()
    let destination = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    CGImageDestinationFinalize(destination)
    return out as Data
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
