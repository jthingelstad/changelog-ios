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
    var ready = item
    switch item.operation {
    case .post(var post):
      for i in post.files.indices { post.files[i].upload = String(repeating: "\(prepared)", count: 32) }
      ready.operation = .post(post)
    case .attach(var attach):
      for i in attach.files.indices { attach.files[i].upload = String(repeating: "\(prepared)", count: 32) }
      ready.operation = .attach(attach)
    default:
      break
    }
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

  @Test func filesAddedToAFiledNoteArePostedOnceAndResentAsTheyWere() async throws {
    let outbox = Outbox(file: nil, files: folder())
    let file = QueuedFile(type: "image/jpeg", name: "Photo 1.jpg", size: 5)
    try outbox.keep(Data("BYTES".utf8), as: file)
    let item = try await outbox.enqueue(.attach(NoteAttach(date: "2026-10-29", id: "n1", files: [file])))
    #expect(item.files == [file] && item.changesFiles && !item.canMove && !item.isNote && item.text == nil)
    #expect(item.changing?.date == "2026-10-29" && item.changing?.id == "n1")
    let offline = APIError(status: 0, code: "network", message: "offline")
    let ref = NoteRef(id: "n1", date: "2026-10-29", version: "4.5.137", revision: "r2", token: "Changelog", files: 2)
    let calls = Calls([.failure(offline), .success(.edited(ref))])
    let prepare: Outbox.Preparer = { item, _ throws(APIError) in await calls.prepare(item) }
    _ = await outbox.flush(prepare: prepare) { item throws(APIError) in try await calls.send(item) }
    let report = await outbox.flush(prepare: prepare) { item throws(APIError) in try await calls.send(item) }
    #expect(await calls.prepared == 1)
    let sent = await calls.sent
    #expect(sent.map(\.idempotencyKey) == [item.idempotencyKey, item.idempotencyKey])
    #expect(sent[0].operation == sent[1].operation && sent[0].files.allSatisfy { $0.upload != nil })
    #expect(report.sent.map(\.result) == [.edited(ref)])
    #expect(outbox.url(for: file).map { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) } == false)
  }

  @Test func uploadsAFiledNoteFindsGoneAreMadeAgainOnce() async throws {
    let outbox = Outbox(file: nil, files: folder())
    let file = QueuedFile(type: "audio/mp4", name: "Voice memo.m4a", size: 5)
    try outbox.keep(Data("BYTES".utf8), as: file)
    let item = try await outbox.enqueue(.attach(NoteAttach(date: "2026-10-29", id: "n1", files: [file])))
    let gone = APIError(status: 400, code: "invalid_request", message: "An upload isn't there.", field: "uploads")
    let ref = NoteRef(id: "n1", date: "2026-10-29", version: "4.5.137", revision: "r2", token: "Changelog")
    let calls = Calls([.failure(gone), .success(.edited(ref))])
    let prepare: Outbox.Preparer = { item, _ throws(APIError) in await calls.prepare(item) }
    let report = await outbox.flush(prepare: prepare) { item throws(APIError) in try await calls.send(item) }
    #expect(await calls.prepared == 2)
    let keys = await calls.sent.map(\.idempotencyKey)
    #expect(keys.count == 2 && keys[0] == item.idempotencyKey && keys[1] != item.idempotencyKey)
    #expect(report.sent.count == 1 && report.refused.isEmpty)
  }

  @Test func aSweepKeepsFilesWaitingToBeAddedToAFiledNote() async throws {
    let outbox = Outbox(file: nil, files: folder())
    let waiting = QueuedFile(type: "image/jpeg", name: "a.jpg", size: 1)
    let stray = QueuedFile(type: "image/jpeg", name: "b.jpg", size: 1)
    for f in [waiting, stray] { try outbox.keep(Data("x".utf8), as: f) }
    try await outbox.enqueue(.attach(NoteAttach(date: "2026-10-29", id: "n1", files: [waiting])))
    await outbox.sweep()
    let exists = { (f: QueuedFile) in outbox.url(for: f).map { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) } ?? false }
    #expect(exists(waiting) && !exists(stray))
  }

  @Test func addingAndTakingOffFilesAsTheAPIAsks() async throws {
    let answer = #"{"note":{"id":"n1","date":"2026-10-29","version":"4.5.137","revision":"r2","token":"Changelog","files":1}}"#
    StubProtocol.set("files.test", .init(status: 200, body: answer))
    let client = stubbedClient("files.test")
    let upload = QueuedFile(type: "image/jpeg", name: "Photo 1.jpg", size: 5, upload: String(repeating: "u", count: 32))
    let attach = OutboxItem(id: UUID(), operation: .attach(NoteAttach(date: "2026-10-29", id: "n1", files: [upload])),
                            queuedAt: .now, attempts: 0, refusal: nil)
    let off = OutboxItem(id: UUID(), operation: .removeFile(date: "2026-10-29", id: "n1", n: 2), queuedAt: .now, attempts: 0, refusal: nil)
    let ref = NoteRef(id: "n1", date: "2026-10-29", version: "4.5.137", revision: "r2", token: "Changelog", files: 1)
    #expect(try await client.perform(attach) == .edited(ref))
    #expect(try await client.perform(off) == .edited(ref))
    let requests = StubProtocol.requests("files.test")
    #expect(requests.map(\.httpMethod) == ["POST", "DELETE"])
    #expect(requests.map { $0.url?.path() } == ["/v1/notes/2026-10-29/n1/media", "/v1/notes/2026-10-29/n1/media/2"])
    #expect(requests.map { $0.value(forHTTPHeaderField: "Idempotency-Key") } == [attach.idempotencyKey, off.idempotencyKey])
    let body = try #require(requests[0].httpBody.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
    let uploads = try #require(body["uploads"] as? [[String: String]])
    #expect(uploads == [["upload": String(repeating: "u", count: 32), "type": "image/jpeg", "name": "Photo 1.jpg"]])
    // A file gone already, or its note, is what was asked: done, never a refusal.
    StubProtocol.set("files.test", .init(status: 404, body: #"{"error":{"code":"not_found","message":"No such file."}}"#))
    #expect(try await client.perform(off) == .done)
  }

  @Test func anEditGoesWordsFirstThenFilesOffThenFilesOn() async throws {
    let photo = QueuedFile(type: "image/jpeg", name: "Photo 1.jpg", size: 5)
    let change = NoteChange(date: "2026-10-29", id: "n1", revision: "r1", wordsNow: "Old words", filesNow: 3,
                            words: "New words", adding: [photo], removing: [3, 1])
    #expect(change.operations == [
      .edit(date: "2026-10-29", id: "n1", text: "New words", revision: "r1"),
      .removeFile(date: "2026-10-29", id: "n1", n: 1),
      .removeFile(date: "2026-10-29", id: "n1", n: 3),
      .attach(NoteAttach(date: "2026-10-29", id: "n1", files: [photo]))
    ])
    #expect(change.refusal == nil && change.filesAfter == 2)
    #expect(NoteChange(date: "2026-10-29", id: "n1", revision: "r1", wordsNow: "", filesNow: 1).isEmpty)
    #expect(NoteChange(date: "2026-10-29", id: "n1", revision: "r1", wordsNow: "w", filesNow: 2, removing: [2]).operations
      == [.removeFile(date: "2026-10-29", id: "n1", n: 2)])
    let outbox = Outbox(file: nil, files: folder())
    let queued = try await outbox.enqueue(change.operations, account: "a1")
    #expect(await outbox.waiting.map(\.operation) == change.operations)
    #expect(Set(queued.map(\.id)).count == 4 && queued.allSatisfy { $0.account == "a1" })
  }

  @Test func aNoteWithNoWordsKeepsAFileAtEveryStep() {
    let photo = QueuedFile(type: "image/jpeg", name: "Photo 1.jpg", size: 5)
    // Both of its files go for a new one: the last goes once the new one is on.
    let swap = NoteChange(date: "2026-10-29", id: "n1", revision: "r1", wordsNow: "", filesNow: 2, adding: [photo], removing: [1, 2])
    #expect(swap.operations == [
      .removeFile(date: "2026-10-29", id: "n1", n: 1),
      .attach(NoteAttach(date: "2026-10-29", id: "n1", files: [photo])),
      .removeFile(date: "2026-10-29", id: "n1", n: 2)
    ])
    #expect(swap.refusal == nil)
    // With words given first, its files can all go before the new one.
    var worded = swap
    worded.words = "Now with words"
    #expect(worded.operations.map(\.removing) == [nil, 1, 2, nil])
    // Some of its files kept: off first, as any note.
    var partial = swap
    partial.removing = [1]
    #expect(partial.operations.map(\.removing) == [1, nil])
    // A full set for its two: one on, the last old one off, then the rest,
    // so the note holds at least one file and never more than it may.
    let full = (0..<MediaType.maxFiles).map { QueuedFile(type: "image/jpeg", name: "Photo \($0).jpg", size: 5) }
    var whole = swap
    whole.adding = full
    #expect(whole.refusal == nil)
    #expect(whole.operations == [
      .removeFile(date: "2026-10-29", id: "n1", n: 1),
      .attach(NoteAttach(date: "2026-10-29", id: "n1", files: [full[0]])),
      .removeFile(date: "2026-10-29", id: "n1", n: 2),
      .attach(NoteAttach(date: "2026-10-29", id: "n1", files: Array(full.dropFirst())))
    ])
    for change in [swap, worded, partial, whole] {
      var held = change.filesNow
      for operation in change.operations {
        switch operation {
        case .removeFile: held -= 1
        case .attach(let attach): held += attach.files.count
        default: continue
        }
        #expect((1...MediaType.maxFiles).contains(held) || change.words != nil)
      }
      #expect(held == change.filesAfter)
    }
  }

  @Test func aChangeSaysWhatReleaseNotesWouldRefuse() {
    let note = NoteDetail(id: "n1", date: "2026-10-29", text: "Words", revision: "r1", writtenAt: nil, files: 1)
    #expect(NoteChange(note, words: "Words").isEmpty)
    #expect(NoteChange(note, words: "Words", removing: [1]).refusal == nil)
    #expect(NoteChange(note, words: " \n").refusal?.contains("can change but not go") == true)
    let photos = NoteDetail(id: "n2", date: "2026-10-29", text: "", revision: "r1", writtenAt: nil, files: 1)
    // Blank where it was blank is no change to its words.
    #expect(NoteChange(photos, words: " ").isEmpty)
    #expect(NoteChange(photos, words: "", removing: [1]).refusal?.contains("keeps its last file") == true)
    #expect(NoteChange(photos, words: "Now words", removing: [1]).refusal == nil)
    let full = (0..<MediaType.maxFiles).map { QueuedFile(type: "image/jpeg", name: "Photo \($0).jpg", size: 5) }
    #expect(NoteChange(photos, words: "", adding: full).refusal == "A note holds up to \(MediaType.maxFiles) files.")
    #expect(NoteChange(photos, words: "", adding: full, removing: [1]).refusal == nil)
  }

  @Test func writesThatGoTogetherAreQueuedAllOrNone() async throws {
    let dir = folder()
    let file = dir.appending(path: "outbox.json")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let outbox = Outbox(file: file)
    try await outbox.enqueue(.pins(["lake"]))
    // The queue's file can't be written: nothing of the edit is kept.
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path(percentEncoded: false))
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path(percentEncoded: false)) }
    let change = NoteChange(date: "2026-10-29", id: "n1", revision: "r1", wordsNow: "w", filesNow: 1, words: "x", removing: [1])
    await #expect(throws: OutboxNotKept.self) { try await outbox.enqueue(change.operations) }
    #expect(await outbox.waiting.map(\.operation) == [.pins(["lake"])])
  }

  @Test func aChangeGoesInOrderAndARefusalHoldsTheRest() async throws {
    let dir = folder()
    let file = dir.appending(path: "outbox.json")
    let change = NoteChange(date: "2026-10-29", id: "n1", revision: "r1", wordsNow: "w", filesNow: 2, words: "x", removing: [1, 2])
    let queued = try await Outbox(file: file).enqueue(change.operations, account: "a1")
    #expect(queued.count == 3 && Set(queued.compactMap(\.group)).count == 1)
    let alone = try await Outbox(file: file).enqueue(.pins(["lake"]), account: "a1")
    #expect(alone.group == nil)
    // The words were changed elsewhere: the files stay on until the words
    // are fixed, and what stands alone still goes.
    let changed = APIError(status: 409, code: "revision_mismatch", message: "Changed since it was read.", revision: "r2")
    let calls = Calls([.failure(changed), .success(.done)])
    var outbox = Outbox(file: file)
    let report = await outbox.flush(for: .account("a1")) { item throws(APIError) in try await calls.send(item) }
    #expect(await calls.sent.map(\.id) == [queued[0].id, alone.id])
    #expect(report.refused.map(\.id) == [queued[0].id] && report.stopped == nil)
    #expect(await outbox.waiting.map(\.status).suffix(2) == Array(repeating: Outbox.afterChange, count: 2))
    // Still held after a relaunch: nothing goes.
    outbox = Outbox(file: file)
    let idle = Calls([])
    _ = await outbox.flush(for: .account("a1")) { item throws(APIError) in try await idle.send(item) }
    #expect(await idle.sent.isEmpty)
    // Fixed, the words go and then the files come off, in order.
    try await outbox.retry(queued[0].id, text: "x", revision: "r2")
    let ref = NoteRef(id: "n1", date: "2026-10-29", version: "4.5.137", revision: "r3", token: "Changelog")
    let fixed = Calls([.success(.edited(ref)), .success(.edited(ref)), .success(.edited(ref))])
    _ = await outbox.flush(for: .account("a1")) { item throws(APIError) in try await fixed.send(item) }
    #expect(await fixed.sent.map(\.operation) == [
      .edit(date: "2026-10-29", id: "n1", text: "x", revision: "r2"),
      .removeFile(date: "2026-10-29", id: "n1", n: 1),
      .removeFile(date: "2026-10-29", id: "n1", n: 2)
    ])
    #expect(await outbox.waiting.isEmpty)
  }

  @Test func discardingAStepDiscardsTheRestOfItsChange() async throws {
    let outbox = Outbox(file: nil, files: folder())
    let photo = QueuedFile(type: "image/jpeg", name: "Photo 1.jpg", size: 5)
    try outbox.keep(Data("BYTES".utf8), as: photo)
    let change = NoteChange(date: "2026-10-29", id: "n1", revision: "r1", wordsNow: "w", filesNow: 2, words: "x",
                            adding: [photo], removing: [1])
    let queued = try await outbox.enqueue(change.operations)
    let alone = try await outbox.enqueue(.pins(["lake"]))
    // A later step goes alone, with what follows it; what came before stays.
    await outbox.discard(queued[1].id)
    #expect(await outbox.waiting.map(\.id) == [queued[0].id, alone.id])
    #expect(outbox.url(for: photo).map { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) } == false)
    await outbox.discard(queued[0].id)
    #expect(await outbox.waiting.map(\.id) == [alone.id])
    // One write alone is only itself.
    let single = try await outbox.enqueue([.pins(["dock"])])
    #expect(single.first?.group == nil)
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

  private func form(_ storage: String) -> String {
    """
    {"upload":"\(String(repeating: "f", count: 32))","type":"image/jpeg","url":"https://\(storage)/up",
     "fields":{"key":"k","policy":"p"},"expires_in":300}
    """
  }

  private func preparing(_ host: String) async throws -> (OutboxItem, URL) {
    let dir = folder()
    let outbox = Outbox(file: nil, files: dir)
    let file = QueuedFile(type: "image/jpeg", name: "lake.jpg", size: 5)
    try outbox.keep(Data("BYTES".utf8), as: file)
    let item = OutboxItem(id: UUID(), operation: .post(NotePost(text: "x", writtenAt: "2026-10-29T07:45:00-05:00", files: [file])),
                          queuedAt: .now, attempts: 0, refusal: nil)
    return (item, dir)
  }

  /// File storage turning a file away (the form expired, say) gets one more
  /// try with a new form; refused again, it is the note's refusal, so it
  /// never holds back the notes after it. Storage's status is never taken
  /// for Release Notes': a 401 there doesn't sign out.
  @Test func aStorageRefusalIsTheNotesOnceANewFormIsRefusedToo() async throws {
    StubProtocol.set("queue-forms.test", .init(status: 201, body: form("queue-refusing-storage.test")))
    StubProtocol.set("queue-refusing-storage.test", .init(status: 401, body: "<Error><Code>AccessDenied</Code></Error>"))
    let (item, dir) = try await preparing("queue-forms.test")
    do {
      _ = try await stubbedClient("queue-forms.test").prepare(item, files: dir)
      Issue.record("expected a refusal")
    } catch {
      #expect(error.code == "upload_refused" && !error.retryable && !error.signedOut)
      #expect(!error.message.contains("AccessDenied"))
    }
    #expect(StubProtocol.requests("queue-forms.test").count == 2)
    #expect(StubProtocol.requests("queue-refusing-storage.test").count == 2)
  }

  /// Storage busy or failing is tried again later, under the same key.
  @Test func aBusyStorageIsTriedAgainLater() async throws {
    StubProtocol.set("queue-busy-forms.test", .init(status: 201, body: form("queue-busy-storage.test")))
    StubProtocol.set("queue-busy-storage.test", .init(status: 503, body: "<Error><Code>SlowDown</Code></Error>"))
    let (item, dir) = try await preparing("queue-busy-forms.test")
    do {
      _ = try await stubbedClient("queue-busy-forms.test").prepare(item, files: dir)
      Issue.record("expected an error")
    } catch {
      #expect(error.code == "upload_failed" && error.retryable)
    }
    #expect(StubProtocol.requests("queue-busy-forms.test").count == 1)
  }

  /// A file gone from the phone is gone for good. One still there that
  /// can't be got ready (the phone full, or locked) waits, and says why.
  @Test func aFileGoneIsMissingButOneThatCantBeReadWaits() async throws {
    let dir = folder()
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let form = UploadForm(upload: String(repeating: "f", count: 32), type: "image/jpeg",
                          url: URL(string: "https://queue-unused-storage.test/up")!, fields: [:], expiresIn: 300)
    let client = stubbedClient("queue-unused.test")
    do {
      try await client.post(fileAt: dir.appending(path: "gone.jpg"), name: "gone.jpg", to: form)
      Issue.record("expected an error")
    } catch {
      #expect(error.code == "file_missing" && !error.retryable)
    }
    let locked = dir.appending(path: "locked.jpg")
    try Data("BYTES".utf8).write(to: locked)
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path(percentEncoded: false))
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: locked.path(percentEncoded: false)) }
    do {
      try await client.post(fileAt: locked, name: "locked.jpg", to: form)
      Issue.record("expected an error")
    } catch {
      #expect(error.code == "no_room" && error.retryable)
      #expect(Outbox.held(error) == "Waiting for room on this phone")
    }
    #expect(StubProtocol.requests("queue-unused-storage.test").isEmpty)
  }
}

extension OutboxOperation {
  /// The file a removal takes off, for checking an order.
  fileprivate var removing: Int? {
    if case .removeFile(_, _, let n) = self { n } else { nil }
  }
}
