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

  /// Files put on and taken off a note already filed, in the order a
  /// NoteChange gives, and a note with no words never left with no file.
  @Test func filesOnAndOffAFiledNote() async throws {
    let client = DevServer.client()
    guard try await client.me().token.scopes.contains("media:write") else { return }
    let folder = FileManager.default.temporaryDirectory.appending(path: "changelog dev " + UUID().uuidString, directoryHint: .isDirectory)
    let outbox = Outbox(file: nil, files: folder)
    let prepare: Outbox.Preparer = { item, folder throws(APIError) in try await client.prepare(item, files: folder) }
    let send: Outbox.Sender = { item throws(APIError) in try await client.perform(item) }
    let png = Self.png()
    func photo(_ n: Int) throws -> QueuedFile {
      let file = QueuedFile(type: "image/png", name: "Photo \(n).png", size: png.count)
      try outbox.keep(png, as: file)
      return file
    }

    try await outbox.enqueue(text: "Files on and off #devtest")
    var report = await outbox.flush(prepare: prepare, send)
    let worded = try #require(report.filed.first).note
    var note = try await client.note(date: worded.date, id: worded.id)
    try await outbox.enqueue(NoteChange(note, words: note.text, adding: [try photo(1), try photo(2)]).operations)
    report = await outbox.flush(prepare: prepare, send)
    #expect(report.stopped == nil && report.refused.isEmpty)
    note = try await client.note(date: worded.date, id: worded.id)
    #expect(note.media?.map(\.n) == [1, 2])

    // New words and a file off together.
    let stale = note
    try await outbox.enqueue(NoteChange(note, words: "Files on and off, edited #devtest", removing: [1]).operations)
    report = await outbox.flush(prepare: prepare, send)
    #expect(report.stopped == nil && report.refused.isEmpty && report.sent.count == 2)
    note = try await client.note(date: worded.date, id: worded.id)
    #expect(note.media?.map(\.n) == [2])
    #expect(note.text == "Files on and off, edited #devtest")
    // From a revision since changed: the words are refused, and the file
    // asked off with them stays on, held behind them; discarded, both go.
    try await outbox.enqueue(NoteChange(stale, words: "Stale words #devtest", removing: [2]).operations)
    report = await outbox.flush(prepare: prepare, send)
    #expect(report.refused.count == 1 && report.sent.isEmpty)
    #expect(await outbox.waiting.last?.status == Outbox.afterChange)
    #expect(try await client.note(date: worded.date, id: worded.id).media?.map(\.n) == [2])
    await outbox.discard(try #require(report.refused.first).id)
    #expect(await outbox.waiting.isEmpty)
    // A file already gone, taken off again, is done rather than refused.
    try await outbox.enqueue(.removeFile(date: worded.date, id: worded.id, n: 1))
    report = await outbox.flush(prepare: prepare, send)
    #expect(report.refused.isEmpty && report.sent.count == 1)

    // A note with no words: its one photo swapped for two others, one on
    // before it comes off.
    try await outbox.enqueue(.post(NotePost(text: "", writtenAt: Timestamp.string(.now), files: [try photo(3)])))
    report = await outbox.flush(prepare: prepare, send)
    let bare = try #require(report.filed.first).note
    note = try await client.note(date: bare.date, id: bare.id)
    #expect(NoteChange(note, words: "", removing: [1]).refusal != nil)
    try await outbox.enqueue(NoteChange(note, words: "", adding: [try photo(4), try photo(5)], removing: [1]).operations)
    report = await outbox.flush(prepare: prepare, send)
    #expect(report.stopped == nil && report.refused.isEmpty && report.sent.count == 3)
    note = try await client.note(date: bare.date, id: bare.id)
    #expect(note.media?.map(\.n) == [2, 3])
    // Its files taken off one by one, alone: Release Notes refuses the
    // last, and it waits.
    try await outbox.enqueue(.removeFile(date: bare.date, id: bare.id, n: 2))
    try await outbox.enqueue(.removeFile(date: bare.date, id: bare.id, n: 3))
    report = await outbox.flush(prepare: prepare, send)
    #expect(report.sent.count == 1 && report.refused.count == 1)
    #expect(try await client.note(date: bare.date, id: bare.id).media?.map(\.n) == [3])

    for gone in [worded, bare] { try await client.deleteNote(date: gone.date, id: gone.id, idempotencyKey: UUID().uuidString.lowercased()) }
  }

  /// API 1.4.0: the account and the token's id, this token's rows carrying
  /// it; and a note held for another account, its file prepared there, goes
  /// to this one only once moved, under its own key, its file posted again.
  @Test func accountsAndTokenIds() async throws {
    let client = DevServer.client()
    let me = try await client.me()
    let account = try #require(me.account)
    let tokenId = try #require(me.token.id)
    #expect(account.wholeMatch(of: /acct_[0-9a-f]{32}/) != nil)
    #expect(tokenId.wholeMatch(of: /[0-9a-f]{32}/) != nil)
    let made = try await client.createNote(NoteRequest(text: "Mine by id #devtest"), idempotencyKey: UUID().uuidString.lowercased())
    let rows = try await client.activity(limit: 50).items
    let row = try #require(rows.first { $0.kind == "note.added" && $0.note == made.note.id })
    #expect(row.tokenId == tokenId)
    #expect(TodayWords.isMine(row, token: me.token))

    guard me.token.scopes.contains("media:write") else { return }
    let folder = FileManager.default.temporaryDirectory.appending(path: "changelog dev " + UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: folder) }
    let outbox = Outbox(file: nil, files: folder)
    let prepare: Outbox.Preparer = { item, folder throws(APIError) in try await client.prepare(item, files: folder) }
    let send: Outbox.Sender = { item throws(APIError) in try await client.perform(item) }
    let png = Self.png()
    var photo = QueuedFile(type: "image/png", name: "Photo 1.png", size: png.count)
    try outbox.keep(png, as: photo)
    // Its upload made under the other account: this one never had it.
    photo.upload = String(repeating: "0", count: 32)
    let held = try await outbox.enqueue(.post(NotePost(text: "Held #devtest", writtenAt: Timestamp.string(.now), files: [photo])),
                                        account: "acct_" + String(repeating: "0", count: 32))
    var report = await outbox.flush(for: .account(account), prepare: prepare, send)
    #expect(report.sent.isEmpty && report.stopped == nil)
    try await outbox.move(held.id, to: account)
    report = await outbox.flush(for: .account(account), prepare: prepare, send)
    #expect(report.refused.isEmpty && report.stopped == nil)
    let went = try #require(report.sent.first?.item)
    #expect(went.idempotencyKey == held.idempotencyKey)
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

  /// Needs a token that may read every note. The dev server's own can't, so
  /// this checks nothing with that one: make one on its Settings page.
  @Test func aReadingTokenReadsTheArchive() async throws {
    let client = DevServer.client()
    let me = try await client.me()
    guard me.token.readsAll else { return }
    let words = "Read from anywhere \(UUID().uuidString.prefix(6))"
    let made = try await client.createNote(NoteRequest(text: words), idempotencyKey: UUID().uuidString.lowercased()).note
    let today = try await client.notes(from: made.date, to: made.date, urls: true)
    let found = try #require(today.items.first { $0.id == made.id })
    #expect(found.text == words)
    #expect(found.version != nil)
    #expect(found.parts != nil)
    let read = try await client.note(date: made.date, id: made.id, urls: true)
    #expect(!read.sourceName.isEmpty)
    let list = try await client.days(limit: 3)
    #expect(list.today == me.today)
    #expect(!list.days.isEmpty)
    let day = try await client.day(made.date, urls: true)
    #expect(day.notes.contains { $0.id == made.id } || day.next != nil)
    if let after = day.next { _ = try await client.notes(from: made.date, to: made.date, after: after, urls: true) }
    try await client.deleteNote(date: made.date, id: made.id, idempotencyKey: UUID().uuidString.lowercased())
  }

  /// Search by a word and by a tag finds the note, and On this day reads.
  @Test func aReadingTokenSearches() async throws {
    let client = DevServer.client()
    guard try await client.me().token.readsAll else { return }
    let mark = "find\(UUID().uuidString.prefix(6).lowercased())"
    let made = try await client.createNote(NoteRequest(text: "Looked for \(mark) at the lake #\(mark)tag"),
                                           idempotencyKey: UUID().uuidString.lowercased()).note
    let byWord = try await client.search(.words(mark), urls: true)
    #expect(byWord.items.map(\.id) == [made.id])
    #expect(byWord.total == 1)
    let byTag = try await client.search(try #require(NoteSearch("#\(mark)tag")))
    #expect(byTag.items.map(\.id) == [made.id])
    let none = try await client.search(.words("\(mark) nowhere\(mark)"))
    #expect(none.items.isEmpty && none.next == nil)
    let past = try await client.onThisDay(urls: true)
    #expect(past.days.allSatisfy { $0.date < past.date && $0.notesTotal >= $0.notes.count })
    try await client.deleteNote(date: made.date, id: made.id, idempotencyKey: UUID().uuidString.lowercased())
  }

  /// The map's pins (API 1.19.0): each says when its note was written, and
  /// words or a tag keep the pins of the notes a search finds.
  @Test func mapPinsFindWordsAndTags() async throws {
    let client = DevServer.client()
    guard try await client.me().token.readsAll else { return }
    let mark = "pin\(UUID().uuidString.prefix(6).lowercased())"
    let place = try await client.here(Spot(lat: 46.79, lon: -92.1, accuracyM: 30)).place
    let lake = try await client.createNote(NoteRequest(text: "By the \(mark) shore #\(mark)tag", place: place),
                                           idempotencyKey: UUID().uuidString.lowercased()).note
    let other = try await client.createNote(NoteRequest(text: "Elsewhere on the lake", place: place),
                                            idempotencyKey: UUID().uuidString.lowercased()).note
    var every: [NotePin] = []
    var after: String?
    repeat {
      let page = try await client.mapPins(after: after)
      every += page.pins
      after = page.next
    } while after != nil
    let made = every.filter { [lake.id, other.id].contains($0.id) }
    #expect(made.count == 2)
    #expect(made.allSatisfy { $0.writtenAt != nil })
    #expect(try await client.mapPins(.words(mark)).pins.map(\.id) == [lake.id])
    #expect(try await client.mapPins(.tag("\(mark)tag")).pins.map(\.id) == [lake.id])
    #expect(try await client.mapPins(.words("\(mark) nowhere")).pins.isEmpty)
    for note in [lake, other] {
      try await client.deleteNote(date: note.date, id: note.id, idempotencyKey: UUID().uuidString.lowercased())
    }
  }

  /// A stop through the queue as a phone reports it: an arrival, then its
  /// leaving under another key, one stay. Then its name and its deleting.
  @Test func aVisitReportedTwiceIsOneStayNamedThenDeleted() async throws {
    let client = DevServer.client()
    let arrival = Date.now.addingTimeInterval(-3600)
    let arriving = try #require(CheckInReport.visit(arrival: arrival, departure: .distantFuture, lat: 44.9778, lon: -93.2650, accuracy: 120))
    let leaving = try #require(CheckInReport.visit(arrival: arrival, departure: .now.addingTimeInterval(-600), lat: 44.9778, lon: -93.2650, accuracy: 60))

    let first = try await client.report(arriving, idempotencyKey: UUID().uuidString).checkIn
    #expect(first.left == nil && first.source == "visit")
    let second = try await client.report(leaving, idempotencyKey: UUID().uuidString).checkIn
    #expect(second.id == first.id, "the same stay")
    #expect(second.left != nil)

    let page = try await client.checkIns(from: first.day, to: first.day)
    let found = try #require(page.items.first { $0.answers(to: first.id) })
    #expect(found.left != nil)
    #expect(try CheckInWords.stay(arrived: found.arrived, left: found.left, source: found.source, timeZone: #require(TimeZone(identifier: "UTC"))) != nil)

    let named = try await client.nameCheckIn(id: found.id, name: "Workshop", revision: found.revision, idempotencyKey: UUID().uuidString)
    #expect(named.label == "Workshop" && named.namedBy == "own" && named.isNamed)
    let off = try await client.nameCheckIn(id: named.id, name: nil, revision: named.revision, idempotencyKey: UUID().uuidString)
    #expect(off.name == nil && off.namedBy != "own", "null takes it off")

    await #expect(throws: APIError.self, "an old revision is refused") {
      _ = try await client.nameCheckIn(id: found.id, name: "Stale", revision: found.revision, idempotencyKey: UUID().uuidString)
    }

    let activity = try await client.activity(kinds: ["checkin"], limit: 20)
    let rows = activity.items.filter { $0.checkin == first.id && $0.kind == "checkin" }
    #expect(rows.count == 1, "one stay, one row")
    let row = try #require(rows.first)
    #expect(row.opens == .checkIn(day: first.day, id: first.id))
    #expect(row.source == "visit" && row.stayLine != nil)

    try await client.deleteCheckIn(id: off.id, idempotencyKey: UUID().uuidString)
    let after = try await client.checkIns(from: first.day, to: first.day)
    #expect(!after.items.contains { $0.answers(to: first.id) })
  }

  @Test func aTapThroughTheOutboxIsNeverContinued() async throws {
    let client = DevServer.client(), outbox = Outbox(file: nil)
    let spot = Spot(lat: 44.9778, lon: -93.2650, accuracyM: 15)
    try await outbox.enqueue(.checkIn(.tap(at: .now, spot: spot)))
    let report = await outbox.flush { (item) async throws(APIError) -> OutboxResult in try await client.perform(item) }
    #expect(report.stopped == nil)
    guard case .checkedIn(let stay)? = report.sent.first?.result else { Issue.record("no check-in came back"); return }
    #expect(stay.source == "tap" && stay.left == nil)
    try await client.deleteCheckIn(id: stay.id, idempotencyKey: UUID().uuidString)
  }

  /// A token without `notes:all` can read remembered places, not change them.
  @Test func rememberedPlacesRead() async throws {
    let client = DevServer.client()
    _ = try await client.rememberedPlaces()
    let me = try await client.me()
    if !me.token.changesAll {
      await #expect(throws: APIError.self) {
        _ = try await client.remember(name: "Workshop", lat: 44.9778, lon: -93.2650, idempotencyKey: UUID().uuidString)
      }
    }
  }

  /// Ignore this location (API 1.20.0): no stop there is kept, the ones there
  /// hide and come back, and Delete existing check-ins here goes only for the
  /// count shown. Needs a token that may change every note.
  @Test func anIgnoredPlaceKeepsNothingAndHidesWhatIsThere() async throws {
    let client = DevServer.client()
    guard try await client.me().token.changesAll else { return }
    func key() -> String { UUID().uuidString.lowercased() }
    // A spot of its own, well away from the other tests' stops.
    let (lat, lon) = (47.0207, -91.6707)
    let arrival = Date.now.addingTimeInterval(-7200)
    let visit = try #require(CheckInReport.visit(arrival: arrival, departure: arrival.addingTimeInterval(1800), lat: lat, lon: lon, accuracy: 30))
    let first = try await client.report(visit, idempotencyKey: key())
    #expect(first.kept, "kept before the place is ignored")
    let stay = first.checkIn
    let place = try await client.remember(name: "Cabin \(UUID().uuidString.prefix(6))", lat: lat, lon: lon, idempotencyKey: key())
    #expect(!place.ignored)
    #expect(try await client.rememberedPlace(id: place.id).checkIns == 1)

    let ignored = try await client.setPlaceIgnored(id: place.id, ignored: true, idempotencyKey: key())
    #expect(ignored.ignored && ignored.name == place.name)
    #expect(try await client.rememberedPlaces().first { $0.id == place.id }?.ignored == true, "still listed, ignored")
    #expect(try await !client.checkIns(from: stay.day, to: stay.day).items.contains { $0.answers(to: stay.id) }, "hidden")
    let log = try await client.activity(kinds: ["checkin"], limit: 50).items
    #expect(log.contains { $0.kind == "checkin.ignored" && $0.place == place.id })
    #expect(!log.contains { $0.kind == "checkin" && $0.checkin == stay.id }, "a hidden stay has no row")

    // A tap there through the queue: done, nothing kept, never sent again.
    let outbox = Outbox(file: nil)
    try await outbox.enqueue(.checkIn(.tap(at: .now, spot: Spot(lat: lat, lon: lon, accuracyM: 10))))
    let report = await outbox.flush { (item) async throws(APIError) -> OutboxResult in try await client.perform(item) }
    #expect(report.stopped == nil && report.refused.isEmpty)
    #expect(report.sent.map(\.result) == [.notKept(at: place.name)])
    #expect(await outbox.waiting.isEmpty)
    #expect(try await client.rememberedPlace(id: place.id).checkIns == 1, "the tap added nothing; the hidden one counts")

    // Unignored, it shows again.
    let back = try await client.setPlaceIgnored(id: place.id, ignored: false, idempotencyKey: key())
    #expect(!back.ignored)
    #expect(try await client.checkIns(from: stay.day, to: stay.day).items.contains { $0.answers(to: stay.id) }, "back")

    // Deleted only for the count shown, hidden ones too; the place stays.
    _ = try await client.setPlaceIgnored(id: place.id, ignored: true, idempotencyKey: key())
    do {
      _ = try await client.deleteCheckIns(atPlace: place.id, count: 5, idempotencyKey: key())
      Issue.record("another count was let through")
    } catch {
      #expect(error.code == "revision_mismatch" && error.count == 1)
    }
    #expect(try await client.deleteCheckIns(atPlace: place.id, count: 1, idempotencyKey: key()) == 1)
    #expect(try await client.rememberedPlace(id: place.id).checkIns == 0)
    #expect(try await client.rememberedPlaces().contains { $0.id == place.id }, "the place stays")
    let deleted = try await client.activity(kinds: ["checkin"], limit: 50).items
    #expect(deleted.contains { $0.kind == "checkin.deleted" && $0.place == place.id && $0.count == 1 })
    #expect(deleted.first { $0.kind == "checkin.deleted" && $0.place == place.id }?.checkInMore == "1 check-in went.")
    try await client.forgetPlace(id: place.id, idempotencyKey: key())
  }

  /// First-class tags (API 1.21.0) against the real `/v1`: a note's tags
  /// field by name beside its #words, an edit that keeps or replaces it, a
  /// stay's tags, and a place's tags with the offer for the stays already
  /// there, refused for a stale count. Needs a token that may change every
  /// note for the place; the rest runs with the printed token.
  @Test func tagsByName() async throws {
    let client = DevServer.client()
    func key() -> String { UUID().uuidString.lowercased() }
    let mark = String(UUID().uuidString.prefix(6)).lowercased()
    let trip = "Road Trip \(mark)", lake = "🚗 Lake \(mark)"

    // A note: field tags by name, then its #words.
    let made = try await client.createNote(NoteRequest(text: "On the way #dev\(mark)", tags: [trip]), idempotencyKey: key()).note
    var note = try await client.note(date: made.date, id: made.id)
    #expect(note.tagList.map(\.name) == [trip, "dev\(mark)"])
    #expect(note.fieldTags.map(\.name) == [trip])
    #expect(note.tagList.first?.key == (try Hashtags.spelling(trip).get().key), "keyed as this phone keys it")

    // An edit without tags keeps the field's; with them, they replace it.
    let kept = try await client.editNote(date: note.date, id: note.id, text: "Still on the way #dev\(mark)",
                                         revision: note.revision, idempotencyKey: key())
    note = try await client.note(date: kept.date, id: kept.id)
    #expect(note.fieldTags.map(\.name) == [trip])
    let change = NoteChange(note, words: note.text, tags: [try Hashtags.spelling(lake).get()])
    guard case .edit(_, _, let text, let revision, let names)? = change.operations.first else {
      Issue.record("no edit")
      return
    }
    _ = try await client.editNote(date: note.date, id: note.id, text: text, revision: revision, tags: names, idempotencyKey: key())
    note = try await client.note(date: note.date, id: note.id)
    #expect(note.fieldTags.map(\.name) == [lake])

    // A stay: the whole list, from the revision read.
    let arrival = Date.now.addingTimeInterval(-5400)
    let (lat, lon) = (46.7867, -92.1005)
    let visit = try #require(CheckInReport.visit(arrival: arrival, departure: arrival.addingTimeInterval(1200), lat: lat, lon: lon, accuracy: 30))
    let stay = try await client.report(visit, idempotencyKey: key()).checkIn
    let tagged = try await client.tagCheckIn(id: stay.id, tags: [Hashtags.spelling(trip).get()], revision: stay.revision, idempotencyKey: key())
    #expect(tagged.tagList.map(\.name) == [trip])
    await #expect(throws: APIError.self, "an old revision is refused") {
      _ = try await client.tagCheckIn(id: stay.id, tags: [], revision: stay.revision, idempotencyKey: key())
    }
    let found = try await client.checkIns(tag: Hashtags.spelling(trip).get().key)
    #expect(found.items.contains { $0.answers(to: stay.id) })

    // A place: a tag gained offers the stays there, for the count shown.
    if try await client.me().token.changesAll {
      #expect(try await client.allTags().tags.contains { $0.name == lake && $0.notes >= 1 })
      let place = try await client.remember(name: "Harbor \(mark)", lat: lat, lon: lon, idempotencyKey: key())
      let named = try await client.setPlaceTags(id: place.id, tags: [Hashtags.spelling(lake).get()], idempotencyKey: key())
      #expect(named.tags.map(\.name) == [lake])
      #expect(named.checkIns == 1, "a tag gained says how many are there")
      do {
        _ = try await client.tagCheckIns(atPlace: place.id, tags: named.tags, count: 4, idempotencyKey: key())
        Issue.record("another count was let through")
      } catch {
        #expect(error.code == "revision_mismatch" && error.count == 1)
      }
      #expect(try await client.tagCheckIns(atPlace: place.id, tags: named.tags, count: 1, idempotencyKey: key()) == 1)
      let now = try #require(try await client.checkIns(from: stay.day, to: stay.day).items.first { $0.answers(to: stay.id) })
      #expect(now.tagList.map(\.name) == [trip, lake], "they join the stay's own")
      try await client.forgetPlace(id: place.id, idempotencyKey: key())
    }
    try await client.deleteCheckIn(id: stay.id, idempotencyKey: key())
    try await client.deleteNote(date: note.date, id: note.id, idempotencyKey: key())
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
