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

  /// A token that can't add files is refused on the photo, so Fix sends the
  /// words without it, under a new key, and the photo leaves the phone.
  @Test func aRefusedNoteGoesAgainWithoutTheFilesTakenOff() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "outbox retry " + UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let outbox = Outbox(file: root.appending(path: "Application Support/outbox.json"))
    let photo = QueuedFile(type: "image/jpeg", name: "Photo 1.jpg", size: 4)
    let memo = QueuedFile(type: "audio/mp4", name: "Voice memo.m4a", size: 4)
    try outbox.keep(Data("jpeg".utf8), as: photo)
    try outbox.keep(Data("m4a!".utf8), as: memo)
    try await outbox.enqueue(.post(NotePost(text: "The new porch light", writtenAt: "2026-10-29T19:02:00-05:00", files: [photo, memo])))
    let noFiles = APIError(status: 403, code: "scope_required", message: "This token can't add files. Make a token with Add files ticked.")
    _ = await outbox.flush(prepare: { _, _ throws(APIError) in throw noFiles }) { _ throws(APIError) in .deleted }
    let refused = try #require(await outbox.waiting.first)
    #expect(refused.refusal == noFiles.message)

    try await outbox.retry(refused.id, text: "The new porch light, at last", keeping: [memo.id])
    let again = try #require(await outbox.waiting.first)
    #expect(again.refusal == nil && again.idempotencyKey != refused.idempotencyKey)
    #expect(again.text == "The new porch light, at last")
    #expect(again.files == [memo])
    let exists = { (file: QueuedFile) in outbox.url(for: file).map { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) } }
    #expect(exists(photo) == false)
    #expect(exists(memo) == true)

    // The words alone: every file off.
    try await outbox.retry(again.id, text: "The new porch light", keeping: [])
    #expect(await outbox.waiting.first?.files == [])
    #expect(exists(memo) == false)
  }

  /// An edit refused as changed since it was read goes again from the
  /// revision read now, with the owner's words, under a new key.
  @Test func aRefusedEditGoesAgainFromTheNewRevision() async throws {
    let outbox = Outbox(file: nil)
    let edit = try await outbox.enqueue(.edit(date: "2026-10-29", id: "t-1", text: "Painted the shed green", revision: "r-1"))
    let changed = APIError(status: 409, code: "revision_mismatch", message: "That note changed since it was read.", revision: "r-2")
    _ = await outbox.flush { _ throws(APIError) in throw changed }
    #expect(await outbox.waiting.first?.refusal == changed.message)

    try await outbox.retry(edit.id, text: "Painted the shed sage green", revision: "r-2")
    let again = try #require(await outbox.waiting.first)
    #expect(again.operation == .edit(date: "2026-10-29", id: "t-1", text: "Painted the shed sage green", revision: "r-2"))
    #expect(again.refusal == nil && again.idempotencyKey != edit.idempotencyKey)

    // Too long, read at the same revision: it keeps that one.
    try await outbox.retry(again.id, text: "Painted the shed")
    #expect(await outbox.waiting.first?.operation == .edit(date: "2026-10-29", id: "t-1", text: "Painted the shed", revision: "r-2"))
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

  /// A 2xx this build can't read was still done: the note is sent, never set
  /// aside for a Fix that would file it a second time.
  @Test func aDoneAnswerItCantReadIsSent() async throws {
    let outbox = Outbox(file: nil)
    try await outbox.enqueue(text: "one")
    try await outbox.enqueue(text: "two")
    let unread = APIError(status: 201, code: "unreadable", message: "Release Notes answered in a way this version doesn't understand.")
    let script = Script([.failure(unread), .success(.filed(receipt("b")))])
    let report = await outbox.flush { item throws(APIError) in try await script.next(item) }
    #expect(report.sent.map(\.result) == [.done, .filed(receipt("b"))])
    #expect(report.refused.isEmpty && report.stopped == nil)
    #expect(await outbox.waiting.isEmpty)
  }

  /// Before the note itself is asked for (a file's form, say), a 2xx it
  /// can't read is no sign of a note.
  @Test func aDoneAnswerWhilePreparingIsNoNote() async throws {
    let outbox = Outbox(file: nil)
    let photo = QueuedFile(type: "image/jpeg", name: "lake.jpg", size: 5)
    try await outbox.enqueue(.post(NotePost(text: "The lake", writtenAt: "2026-10-29T07:45:00-05:00", files: [photo])))
    let unread = APIError(status: 201, code: "unreadable", message: "Release Notes answered in a way this version doesn't understand.")
    let script = Script([])
    let prepare: Outbox.Preparer = { _, _ throws(APIError) in throw unread }
    let report = await outbox.flush(prepare: prepare) { item throws(APIError) in try await script.next(item) }
    #expect(report.sent.isEmpty && report.refused.count == 1)
    #expect(await script.sent.isEmpty)
  }

  /// Log says why a note waits: a day's limit, Release Notes busy, or no
  /// connection, for the note a run stopped at and those behind it.
  /// A moment from a day Release Notes won't take (before the birthday,
  /// which the app never learns) files to the day it was written, once,
  /// under a new key. A note with no day of its own is refused as before.
  @Test func aDayOutOfRangeFilesToTheDayItWasWritten() async throws {
    let outbox = Outbox(file: nil)
    let dated = try await outbox.enqueue(.note(text: "An old one", date: "1900-01-01", writtenAt: "2026-10-29T07:45:00-05:00"))
    try await outbox.enqueue(.post(NotePost(text: "With a place", date: "1900-01-01", writtenAt: "2026-10-29T07:46:00-05:00")))
    try await outbox.enqueue(.note(text: "Undated", date: nil, writtenAt: "2026-10-29T07:47:00-05:00"))
    let range = APIError(status: 400, code: "date_out_of_range", message: "Choose a day from your birthday through today.", field: "date")
    let script = Script([.failure(range), .success(.filed(receipt("a"))), .failure(range), .success(.filed(receipt("b"))),
                         .failure(range)])
    let report = await outbox.flush { item throws(APIError) in try await script.next(item) }
    let sent = await script.sent
    #expect(sent.map(\.text) == ["An old one", "An old one", "With a place", "With a place", "Undated"])
    #expect(sent[0].idempotencyKey == dated.idempotencyKey && sent[1].idempotencyKey != dated.idempotencyKey)
    #expect(sent[1].operation == .note(text: "An old one", date: nil, writtenAt: "2026-10-29T07:45:00-05:00"))
    if case .post(let post) = sent[3].operation { #expect(post.date == nil) } else { Issue.record("not a post") }
    #expect(report.filed.map(\.note.id) == ["a", "b"])
    #expect(report.refused.map(\.text) == ["Undated"])
  }

  /// A moment's values go with the note under its key, kept through a
  /// resend and a day refused. A Release Notes that won't take them (one
  /// from before moments refuses the field) gets the words alone, once,
  /// under a new key; any other refusal is the owner's to fix, as before.
  @Test func aMomentGoesWithItsNoteOrTheWordsGoAlone() async throws {
    let outbox = Outbox(file: nil)
    let moment = NoteMoment(at: "2026-10-28T07:40:00-05:00",
                            items: [NoteMoment.Item(kind: "workout", activity: "walking", distanceM: 5150, durationS: 2890)])
    let walk = try await outbox.enqueue(.post(NotePost(text: "Walked 3.2 mi in 48 min", date: "1900-01-01",
                                                       writtenAt: "2026-10-29T07:45:00-05:00", moment: moment)))
    try await outbox.enqueue(.post(NotePost(text: "Walked again", writtenAt: "2026-10-29T07:46:00-05:00", moment: moment)))
    try await outbox.enqueue(.post(NotePost(text: "Too long", writtenAt: "2026-10-29T07:47:00-05:00", moment: moment)))
    let range = APIError(status: 400, code: "date_out_of_range", message: "Choose a day from your birthday through today.", field: "date")
    let before = APIError(status: 400, code: "invalid_request", message: "moment isn't a field here.", field: "moment")
    let piece = APIError(status: 400, code: "invalid_request", message: "moment.items[0].kind is one of …", field: "moment.items[0].kind")
    let long = APIError(status: 400, code: "too_long", message: "A note is at most 20,000 characters.", field: "text")
    let script = Script([.failure(.network(URLError(.notConnectedToInternet)))])
    _ = await outbox.flush { item throws(APIError) in try await script.next(item) }
    let resume = Script([.failure(range), .success(.filed(receipt("a"))),
                         .failure(before), .success(.filed(receipt("b"))),
                         .failure(piece), .failure(long)])
    let report = await outbox.flush { item throws(APIError) in try await resume.next(item) }
    let first = await script.sent, sent = await resume.sent
    // A resend is the same request under the same key, moment and all.
    #expect(first[0].idempotencyKey == walk.idempotencyKey && sent[0].idempotencyKey == walk.idempotencyKey)
    #expect(first[0].operation == sent[0].operation)
    // The day refused: the same note, its moment kept, to the day it was written.
    guard case .post(let undated) = sent[1].operation else { Issue.record("not a post"); return }
    #expect(undated.date == nil && undated.moment == moment && undated.request.moment == moment)
    #expect(sent[1].idempotencyKey != walk.idempotencyKey)
    // The field refused: the words alone, under a new key.
    guard case .post(let words) = sent[3].operation else { Issue.record("not a post"); return }
    #expect(sent[2].text == "Walked again" && sent[3].text == "Walked again")
    #expect(words.moment == nil && words.request.moment == nil)
    #expect(sent[3].idempotencyKey != sent[2].idempotencyKey)
    // A piece refused goes without it too, and a refusal of the words is set aside.
    #expect(sent[4].text == "Too long")
    guard case .post(let unpieced) = sent[5].operation else { Issue.record("not a post"); return }
    #expect(unpieced.moment == nil)
    #expect(report.filed.map(\.note.id) == ["a", "b"])
    #expect(report.refused.map(\.text) == ["Too long"])
    // Once, not again: the remade note has no moment to drop.
    #expect(OutboxOperation.post(unpieced).withoutMoment == nil)
  }

  /// A queue saved by a build before moments still reads, and a note with
  /// none sends as it did.
  @Test func aQueueSavedBeforeMomentsReads() throws {
    let older = Data(#"""
      [{"id":"6F1D2C3B-4A59-4E6F-8A7B-9C0D1E2F3A4B","operation":{"post":{"_0":{"text":"With a place",
        "writtenAt":"2026-10-29T07:46:00-05:00","files":[],"reuploads":0}}},"queuedAt":783000000,"attempts":0}]
      """#.utf8)
    let read = try JSONDecoder().decode([OutboxItem].self, from: older)
    guard case .post(let post) = try #require(read.first).operation else { Issue.record("not a post"); return }
    #expect(post.moment == nil && post.text == "With a place")
    let body = try JSONSerialization.jsonObject(with: APIClient.encoder.encode(post.request)) as? [String: String]
    #expect(body == ["text": "With a place", "written_at": "2026-10-29T07:46:00-05:00"])
  }

  /// A note remade under a new key is saved first. When the queue can't be
  /// written, it stays as it was and isn't sent, so a relaunch never remakes
  /// it under a third key and files it twice.
  @Test func aRemadeNoteThatCantBeSavedIsNotSent() async throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: "outbox remade \(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let outbox = Outbox(file: dir.appending(path: "outbox.json"))
    let dated = try await outbox.enqueue(.note(text: "An old one", date: "1900-01-01", writtenAt: "2026-10-29T07:45:00-05:00"))
    // The phone fills up: the queue can no longer be written.
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path(percentEncoded: false))
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path(percentEncoded: false)) }
    let range = APIError(status: 400, code: "date_out_of_range", message: "Choose a day from your birthday through today.", field: "date")
    let script = Script([.failure(range), .success(.filed(receipt("a")))])
    let report = await outbox.flush { item throws(APIError) in try await script.next(item) }
    #expect(await script.sent.map(\.idempotencyKey) == [dated.idempotencyKey])
    #expect(report.stopped?.code == "not_kept" && report.filed.isEmpty && report.refused.isEmpty)
    // Still the dated request under its key, waiting for a run that can keep it.
    let waiting = try #require(await outbox.waiting.first)
    #expect(waiting.id == dated.id && waiting.idempotencyKey == dated.idempotencyKey && waiting.operation == dated.operation)
    #expect(waiting.refusal == nil)
  }

  @Test func eachWaitSaysWhy() async throws {
    let outbox = Outbox(file: nil)
    try await outbox.enqueue(text: "one")
    try await outbox.enqueue(text: "two")
    #expect(await outbox.waiting.map(\.status) == ["Sending…", "Sending…"])
    let limited = APIError(status: 429, code: "rate_limited", message: "That's today's 100 notes through tokens.", retryAfter: 3600)
    let busy = APIError(status: 503, code: "unavailable", message: APIClient.busy)
    let offline = APIError(status: 0, code: "network", message: "offline")
    let script = Script([.failure(limited), .failure(busy), .failure(offline)])
    let send: Outbox.Sender = { item throws(APIError) in try await script.next(item) }
    // The note behind, never tried, waits for the same reason.
    _ = await outbox.flush(send)
    #expect(await outbox.waiting.map(\.status) == ["Waiting for today’s limit to reset", "Waiting for today’s limit to reset"])
    _ = await outbox.flush(send)
    #expect(await outbox.waiting.map(\.status) == ["Waiting for Release Notes", "Waiting for Release Notes"])
    _ = await outbox.flush(send)
    #expect(await outbox.waiting.map(\.status) == ["Waiting for a connection", "Waiting for a connection"])
    #expect(await script.sent.map(\.text) == ["one", "one", "one"])
  }

  /// The day's uploads used holds back only notes with files to post. The
  /// words-only note, the edit (of a note already filed) and the pins behind
  /// go, in order, and the next note with files doesn't ask for a form.
  @Test func aDaysUploadsUsedHoldsOnlyNotesWithFiles() async throws {
    let outbox = Outbox(file: nil)
    let photo = QueuedFile(type: "image/jpeg", name: "lake.jpg", size: 5)
    let memo = QueuedFile(type: "audio/mp4", name: "Voice memo.m4a", size: 5)
    let first = try await outbox.enqueue(.post(NotePost(text: "The lake", writtenAt: "2026-10-29T07:45:00-05:00", files: [photo])))
    try await outbox.enqueue(text: "words")
    try await outbox.enqueue(.edit(date: "2026-10-28", id: "t-1", text: "better", revision: "r-1"))
    let later = try await outbox.enqueue(.post(NotePost(text: "Later", writtenAt: "2026-10-29T08:00:00-05:00", files: [memo])))
    try await outbox.enqueue(.pins(["running"]))
    let limited = APIError(status: 429, code: "rate_limited", message: "That's today's 200 files or 2 GB of uploads for this account.",
                           retryAfter: 3600)
    let ref = NoteRef(id: "t-1", date: "2026-10-28", version: "4.5.136", revision: "r-2", token: "Changelog")
    let tags = Tags(pinned: ["running"], recent: [], windowDays: 30)
    let script = Script([.success(.filed(receipt("b"))), .success(.edited(ref)), .success(.pinned(tags))])
    let forms = Script([.failure(limited)])
    let prepare: Outbox.Preparer = { item, _ throws(APIError) in
      _ = try await forms.next(item)
      return item
    }
    let report = await outbox.flush(prepare: prepare) { item throws(APIError) in try await script.next(item) }
    #expect(await forms.sent.map(\.id) == [first.id])
    #expect(await script.sent.map(\.text) == ["words", "better", nil])
    #expect(report.stopped == limited)
    let waiting = await outbox.waiting
    #expect(waiting.map(\.id) == [first.id, later.id])
    #expect(waiting.map(\.status) == ["Waiting for today’s file limit to reset", "Waiting for today’s file limit to reset"])
  }

  private func folder() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "changelog queue " + UUID().uuidString, directoryHint: .isDirectory)
  }

  /// A queue this build can't read (a newer build's, or damaged) is moved
  /// aside as it was, never written over, and the files it names stay.
  @Test func aQueueItCantReadIsSetAsideNotWrittenOver() async throws {
    let dir = folder()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appending(path: "outbox.json")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let photo = QueuedFile(type: "image/jpeg", name: "lake.jpg", size: 5)
    let newer = """
      [{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","queuedAt":783000000,"attempts":0,
        "operation":{"video":{"text":"one","files":[{"id":"\(photo.id.uuidString)","type":"image/jpeg","name":"lake.jpg","size":5}]}}}]
      """
    try Data(newer.utf8).write(to: file)
    let outbox = Outbox(file: file)
    try outbox.keep(Data("BYTES".utf8), as: photo)
    #expect(await outbox.waiting.isEmpty)
    try await outbox.enqueue(text: "two")
    await outbox.sweep()
    let aside = try #require(SetAside.files(of: file).first)
    #expect(try Data(contentsOf: aside) == Data(newer.utf8))
    #expect(outbox.url(for: photo).map { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) } == true)
    // Read again by this build, it stays aside, as it was.
    let again = Outbox(file: file)
    #expect(await again.waiting.map(\.text) == ["two"])
    #expect(SetAside.files(of: file) == [aside])
  }

  /// A queue set aside comes back once it reads, ahead of what was queued
  /// since, under its own keys; its copy aside goes.
  @Test func aQueueSetAsideComesBackOnceItReads() async throws {
    let dir = folder()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appending(path: "outbox.json")
    let old = try await Outbox(file: file).enqueue(text: "typed offline")
    #expect(SetAside.move(file))
    // Queued since, by a run that couldn't read it.
    let since = dir.appending(path: "since.json")
    let new = try await Outbox(file: since).enqueue(text: "typed later")
    try FileManager.default.moveItem(at: since, to: file)
    let outbox = Outbox(file: file)
    #expect(await outbox.waiting.map(\.id) == [old.id, new.id])
    #expect(SetAside.files(of: file).isEmpty)
    #expect(await Outbox(file: file).waiting.map(\.id) == [old.id, new.id])
  }
}
