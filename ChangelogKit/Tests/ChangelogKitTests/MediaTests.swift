import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import ChangelogKit

/// A tiny image of the given type, made here rather than kept as a file.
private func image(_ type: UTType) -> Data {
  let context = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
  context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
  let out = NSMutableData()
  let destination = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil)!
  CGImageDestinationAddImage(destination, context.makeImage()!, nil)
  CGImageDestinationFinalize(destination)
  return out as Data
}

private func ftyp(_ brand: String) -> Data {
  Data([0, 0, 0, 0x18]) + Data("ftyp\(brand)".utf8) + Data(repeating: 0, count: 8)
}

private func receipt(_ id: String) -> NoteReceipt {
  NoteReceipt(note: NoteRef(id: id, date: "2026-10-29", version: "4.5.137", revision: "r", token: "Changelog"), unlocked: nil)
}

private actor Calls {
  var prepared = 0
  var sent: [OutboxItem] = []
  var outcomes: [Result<OutboxResult, APIError>]
  init(_ outcomes: [Result<OutboxResult, APIError>]) { self.outcomes = outcomes }
  func prepare(_ item: OutboxItem) -> OutboxItem {
    prepared += 1
    guard case .post(var post) = item.operation else { return item }
    for i in post.files.indices { post.files[i].upload = String(repeating: "\(prepared)", count: 32) }
    var ready = item
    ready.operation = .post(post)
    return ready
  }
  func send(_ item: OutboxItem) throws(APIError) -> OutboxResult {
    sent.append(item)
    return try outcomes.removeFirst().get()
  }
}

private func folder() -> URL {
  FileManager.default.temporaryDirectory.appending(path: "Application Support " + UUID().uuidString, directoryHint: .isDirectory)
}

@Suite struct MediaTests {
  @Test func sniffsTheTypesReleaseNotesKeeps() {
    #expect(MediaType.sniff(image(.jpeg)) == "image/jpeg")
    #expect(MediaType.sniff(image(.png)) == "image/png")
    #expect(MediaType.sniff(Data("%PDF-1.7\n".utf8)) == "application/pdf")
    #expect(MediaType.sniff(ftyp("M4A ")) == "audio/mp4")
    #expect(MediaType.sniff(ftyp("heic")) == "image/heic")
    // A video's brand is no recording, and text is nothing at all.
    #expect(MediaType.sniff(ftyp("qt  ")) == nil)
    #expect(MediaType.sniff(Data("hello".utf8)) == nil)
  }

  @Test func photosShowableAsTheyAreStayAsTheyAre() {
    let png = image(.png)
    let kept = MediaType.photo(png)
    #expect(kept?.type == "image/png")
    #expect(kept?.data == png)
  }

  @Test func otherPhotosBecomeJPEG() {
    let made = MediaType.photo(image(.tiff))
    #expect(made?.type == "image/jpeg")
    #expect(made.map { MediaType.sniff($0.data) } == "image/jpeg")
    #expect(MediaType.photo(Data("not an image".utf8)) == nil)
  }

  @Test func theFormPutsEveryFieldBeforeTheFile() throws {
    let body = Multipart.body(fields: ["key": "media/x", "Policy": "p"], file: Data("BYTES".utf8),
                              name: "lake \"dawn\".jpg", type: "image/jpeg", boundary: "b")
    let text = try #require(String(data: body, encoding: .utf8))
    let policy = try #require(text.range(of: "name=\"Policy\""))
    let key = try #require(text.range(of: "name=\"key\""))
    let file = try #require(text.range(of: "name=\"file\"; filename=\"lake %22dawn%22.jpg\""))
    #expect(policy.lowerBound < key.lowerBound && key.lowerBound < file.lowerBound)
    #expect(text.contains("Content-Type: image/jpeg\r\n\r\nBYTES\r\n--b--\r\n"))
  }

  @Test func aNoteWithFilesNeedsNoWordsAndSendsItsPlaceAsItCame() throws {
    let place = DevicePlace(name: "Saint Paul", region: "Minnesota", country: "United States", tz: "America/Chicago",
                            district: "Lowertown", venue: "Corner Coffee", lat: 44.948, lon: -93.086, accuracyM: 20, from: "device")
    var post = NotePost(text: "  ", writtenAt: "2026-10-29T07:45:00-05:00",
                        files: [QueuedFile(type: "image/jpeg", name: "lake.jpg", size: 5, upload: String(repeating: "a", count: 32))],
                        place: place)
    post.spot = Spot(lat: 44.948, lon: -93.086)
    let body = try #require(JSONSerialization.jsonObject(with: APIClient.encoder.encode(post.request)) as? [String: Any])
    #expect(body["text"] == nil)
    #expect(body["written_at"] as? String == "2026-10-29T07:45:00-05:00")
    let uploads = try #require(body["uploads"] as? [[String: String]])
    #expect(uploads == [["upload": String(repeating: "a", count: 32), "type": "image/jpeg", "name": "lake.jpg"]])
    let sent = try #require(body["place"] as? [String: Any])
    #expect(sent["accuracy_m"] as? Double == 20)
    #expect(sent["from"] as? String == "device")
    #expect(sent["venue"] as? String == "Corner Coffee")
    // The spot is the phone's own; only the place it named goes.
    #expect(body["spot"] == nil)
  }

  @Test func filesArePostedOnceAndTheSameRequestIsResent() async throws {
    let outbox = Outbox(file: nil, files: folder())
    let file = QueuedFile(type: "image/jpeg", name: "lake.jpg", size: 5)
    try outbox.keep(Data("BYTES".utf8), as: file)
    let item = try await outbox.enqueue(.post(NotePost(text: "The lake #lake", writtenAt: "2026-10-29T07:45:00-05:00", files: [file])))
    let offline = APIError(status: 0, code: "network", message: "offline")
    let calls = Calls([.failure(offline), .success(.filed(receipt("a")))])
    let prepare: Outbox.Preparer = { item, _ throws(APIError) in await calls.prepare(item) }
    _ = await outbox.flush(prepare: prepare) { item throws(APIError) in try await calls.send(item) }
    // The uploads were saved before the note went, so the resend after the
    // lost answer is the same request under the same key.
    let waiting = try #require(await outbox.waiting.first)
    #expect(waiting.files.first?.upload == String(repeating: "1", count: 32))
    let report = await outbox.flush(prepare: prepare) { item throws(APIError) in try await calls.send(item) }
    #expect(await calls.prepared == 1)
    let sent = await calls.sent
    #expect(sent.map(\.idempotencyKey) == [item.idempotencyKey, item.idempotencyKey])
    #expect(sent[0].operation == sent[1].operation)
    #expect(report.filed.map(\.note.id) == ["a"])
    // Sent, its bytes are gone from the phone.
    #expect(outbox.url(for: file).map { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) } == false)
  }

  @Test func uploadsANoteFindsGoneAreMadeAgainOnceUnderANewKey() async throws {
    let outbox = Outbox(file: nil, files: folder())
    let file = QueuedFile(type: "image/jpeg", name: "lake.jpg", size: 5)
    try outbox.keep(Data("BYTES".utf8), as: file)
    let item = try await outbox.enqueue(.post(NotePost(text: "", writtenAt: "2026-10-29T07:45:00-05:00", files: [file])))
    let gone = APIError(status: 400, code: "invalid_request", message: "An upload isn't there.", field: "uploads")
    let calls = Calls([.failure(gone), .failure(gone), .success(.filed(receipt("a")))])
    let prepare: Outbox.Preparer = { item, _ throws(APIError) in await calls.prepare(item) }
    let report = await outbox.flush(prepare: prepare) { item throws(APIError) in try await calls.send(item) }
    // The first refusal makes the uploads again under a new key; a second is
    // set aside for the owner, with nothing lost.
    #expect(await calls.prepared == 2)
    let keys = await calls.sent.map(\.idempotencyKey)
    #expect(keys.count == 2 && keys[0] == item.idempotencyKey && keys[1] != item.idempotencyKey)
    #expect(report.refused.count == 1)
    #expect(await outbox.waiting.first?.refusal != nil)
  }

  @Test func discardingANoteRemovesItsFiles() async throws {
    let outbox = Outbox(file: nil, files: folder())
    let file = QueuedFile(type: "audio/mp4", name: "Voice memo.m4a", size: 5)
    try outbox.keep(Data("BYTES".utf8), as: file)
    let item = try await outbox.enqueue(.post(NotePost(text: "", writtenAt: "2026-10-29T07:45:00-05:00", files: [file])))
    await outbox.discard(item.id)
    #expect(outbox.url(for: file).map { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) } == false)
  }

  @Test func aSweepKeepsQueuedAndDraftFilesOnly() async throws {
    let outbox = Outbox(file: nil, files: folder())
    let queued = QueuedFile(type: "image/jpeg", name: "a.jpg", size: 1)
    let draft = QueuedFile(type: "image/jpeg", name: "b.jpg", size: 1)
    let stray = QueuedFile(type: "image/jpeg", name: "c.jpg", size: 1)
    for f in [queued, draft, stray] { try outbox.keep(Data("x".utf8), as: f) }
    try await outbox.enqueue(.post(NotePost(text: "", writtenAt: "2026-10-29T07:45:00-05:00", files: [queued])))
    await outbox.sweep(keeping: [draft.id])
    let exists = { (f: QueuedFile) in outbox.url(for: f).map { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) } ?? false }
    #expect(exists(queued) && exists(draft) && !exists(stray))
  }

  @Test func aQueueFromAnEarlierBuildStillReads() async throws {
    let dir = folder()
    let file = dir.appending(path: "outbox.json")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    // An item as 0.1 saved it, before notes could carry files.
    let old = """
      [{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","queuedAt":783000000,"attempts":0,
        "operation":{"note":{"text":"one","writtenAt":"2026-10-29T07:45:00-05:00"}}}]
      """
    try Data(old.utf8).write(to: file)
    let outbox = Outbox(file: file)
    #expect(await outbox.waiting.map(\.text) == ["one"])
  }

  @Test func thePreparerPostsTheFileWithoutTheToken() async throws {
    StubProtocol.set("prep.test", .init(status: 201, body: """
      {"upload":"\(String(repeating: "f", count: 32))","type":"image/jpeg","url":"https://storage.test/up",
       "fields":{"key":"k","policy":"p"},"expires_in":300}
      """))
    StubProtocol.set("storage.test", .init(status: 204, body: ""))
    let dir = folder()
    let outbox = Outbox(file: nil, files: dir)
    let file = QueuedFile(type: "image/jpeg", name: "lake.jpg", size: 5)
    try outbox.keep(Data("BYTES".utf8), as: file)
    let item = OutboxItem(id: UUID(), operation: .post(NotePost(text: "x", writtenAt: "2026-10-29T07:45:00-05:00", files: [file])),
                          queuedAt: .now, attempts: 0, refusal: nil)
    let ready = try await stubbedClient("prep.test").prepare(item, files: dir)
    #expect(ready.files.first?.upload == String(repeating: "f", count: 32))
    let start = try #require(StubProtocol.requests("prep.test").first)
    let asked = try #require(start.httpBody.flatMap { String(data: $0, encoding: .utf8) })
    #expect(asked.contains("\"size\":5") && asked.contains("\"type\":\"image/jpeg\""))
    let upload = try #require(StubProtocol.requests("storage.test").first)
    #expect(upload.value(forHTTPHeaderField: "Authorization") == nil)
    #expect(upload.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary=") == true)
    // Streamed from disk: every field, then the file's bytes, then the end.
    let sent = try #require(upload.httpBody.flatMap { String(data: $0, encoding: .utf8) })
    let policy = try #require(sent.range(of: "name=\"policy\"\r\n\r\np\r\n"))
    let bytes = try #require(sent.range(of: "Content-Type: image/jpeg\r\n\r\nBYTES\r\n--changelog-"))
    #expect(policy.upperBound < bytes.lowerBound && sent.hasSuffix("--\r\n"))
  }

  @Test func aPlaceThatCantBeNamedIsLeftOff() async throws {
    StubProtocol.set("noplace.test", .init(status: 404, body: #"{"error":{"code":"not_found","message":"No city there."}}"#))
    var post = NotePost(text: "At sea", writtenAt: "2026-10-29T07:45:00-05:00")
    post.spot = Spot(lat: 0, lon: -30, accuracyM: 50)
    let item = OutboxItem(id: UUID(), operation: .post(post), queuedAt: .now, attempts: 0, refusal: nil)
    let ready = try await stubbedClient("noplace.test").prepare(item, files: nil)
    guard case .post(let after) = ready.operation else { Issue.record("not a post"); return }
    #expect(after.spot == nil && after.place == nil && after.ready)
  }

  @Test func theDaysSpotsUsedLeaveThePlaceOffButOfflineWaits() async throws {
    StubProtocol.set("spent.test", .init(status: 429, body: #"{"error":{"code":"rate_limited","message":"That's today's 100 places."}}"#,
                                         headers: ["Retry-After": "3600"]))
    var post = NotePost(text: "Lunch", writtenAt: "2026-10-29T12:05:00-05:00")
    post.spot = Spot(lat: 44.948, lon: -93.086, accuracyM: 30)
    let item = OutboxItem(id: UUID(), operation: .post(post), queuedAt: .now, attempts: 0, refusal: nil)
    let ready = try await stubbedClient("spent.test").prepare(item, files: nil)
    guard case .post(let after) = ready.operation else { Issue.record("not a post"); return }
    #expect(after.spot == nil && after.ready)
    do {
      _ = try await stubbedClient("offline-here.test").prepare(item, files: nil)
      Issue.record("expected to wait")
    } catch {
      #expect(error.code == "network")
    }
  }

  @Test func aFixedNoteKeepsItsUploadsUnderANewKey() async throws {
    let outbox = Outbox(file: nil, files: folder())
    let posted = QueuedFile(type: "image/jpeg", name: "a.jpg", size: 1, upload: String(repeating: "a", count: 32))
    let gone = QueuedFile(type: "image/jpeg", name: "b.jpg", size: 1)
    try outbox.keep(Data("x".utf8), as: posted)
    let item = try await outbox.enqueue(.post(NotePost(text: "Too long", writtenAt: "2026-10-29T07:45:00-05:00", files: [posted, gone])))
    let long = APIError(status: 400, code: "invalid_request", message: "That's longer than a note takes.", field: "text")
    let calls = Calls([.failure(long)])
    _ = await outbox.flush { item throws(APIError) in try await calls.send(item) }
    try await outbox.retry(item.id, text: "Shorter")
    let fixed = try #require(await outbox.waiting.first)
    #expect(fixed.idempotencyKey != item.idempotencyKey && fixed.refusal == nil)
    // The posted file keeps its upload; the one never posted, with no bytes, goes.
    #expect(fixed.files == [posted])
    #expect(fixed.text == "Shorter")
  }

  @Test func aPreparedNoteThatCantBeSavedIsNotSent() async throws {
    let dir = folder()
    let outbox = Outbox(file: dir.appending(path: "outbox.json"), files: dir.appending(path: "files"))
    let file = QueuedFile(type: "image/jpeg", name: "lake.jpg", size: 5)
    try outbox.keep(Data("BYTES".utf8), as: file)
    let item = try await outbox.enqueue(.post(NotePost(text: "Full phone", writtenAt: "2026-10-29T07:45:00-05:00", files: [file])))
    // The phone fills up: the queue can no longer be written.
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path(percentEncoded: false))
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path(percentEncoded: false)) }
    let calls = Calls([.success(.filed(receipt("a")))])
    let prepare: Outbox.Preparer = { item, _ throws(APIError) in await calls.prepare(item) }
    let report = await outbox.flush(prepare: prepare) { item throws(APIError) in try await calls.send(item) }
    #expect(await calls.sent.isEmpty)
    #expect(report.stopped?.code == "not_kept" && report.stopped?.retryable == true)
    // Still as it was saved, so the next run prepares it afresh under its key.
    let waiting = try #require(await outbox.waiting.first)
    #expect(waiting.id == item.id && waiting.files.first?.upload == nil)
  }

  @Test func aHereAlreadyAskedForNamesTheQueuedNote() async throws {
    let outbox = Outbox(file: nil)
    let spot = Spot(lat: 44.98, lon: -93.26, accuracyM: 30)
    let item = try await outbox.enqueue(.post(NotePost(text: "Lunch", writtenAt: "2026-10-29T12:05:00-05:00", spot: spot)))
    let place = DevicePlace(name: "Minneapolis", region: "Minnesota", country: "United States", tz: "America/Chicago",
                            district: "Old Town", venue: nil, lat: 44.98, lon: -93.26, accuracyM: 30, from: "device")
    await outbox.name(item.id, spot: spot, place: place)
    guard case .post(let named) = try #require(await outbox.waiting.first).operation else { Issue.record("not a post"); return }
    // Ready as it is: preparing it asks Here nothing.
    #expect(named.place == place && named.ready)
  }
}
