import Foundation

/// What a queued write does. Every write the app makes is one of these, so a
/// lost answer is always resent under the key it went out with.
public enum OutboxOperation: Codable, Sendable, Equatable {
  /// A new note, with the moment its words were typed.
  case note(text: String, date: String?, writtenAt: String)
  /// New words for a note this token wrote, from the revision it read.
  case edit(date: String, id: String, text: String, revision: String)
  case delete(date: String, id: String)
  case pins([String])
  /// A new note with files, a place or both. Its own case, so a queue saved
  /// by an earlier build still reads.
  case post(NotePost)
}

extension OutboxOperation {
  /// A new note filed to a day of its own, made to file to the day it was
  /// written; nil for anything else.
  var undated: OutboxOperation? {
    switch self {
    case .note(let text, .some, let writtenAt):
      return .note(text: text, date: nil, writtenAt: writtenAt)
    case .post(var post) where post.date != nil:
      post.date = nil
      return .post(post)
    default:
      return nil
    }
  }
}

/// A note with files or a place, as queued. The files' bytes wait in the
/// Outbox's folder; each `upload` and the `place` are filled in, and saved,
/// before the note is sent, so every resend is the same request.
public struct NotePost: Codable, Sendable, Equatable {
  public var text: String
  public var date: String?
  public var writtenAt: String
  public var files: [QueuedFile]
  /// Where the phone was, named by Here when the note is sent.
  public var spot: Spot?
  /// The place, as Here named it (with a business, if one was picked).
  public var place: DevicePlace?
  /// Times the uploads were made again after the note found them gone.
  public var reuploads: Int

  public init(text: String, date: String? = nil, writtenAt: String, files: [QueuedFile] = [], spot: Spot? = nil, place: DevicePlace? = nil) {
    self.text = text
    self.date = date
    self.writtenAt = writtenAt
    self.files = files
    self.spot = spot
    self.place = place
    self.reuploads = 0
  }

  /// Every file posted and the place named: ready to send.
  public var ready: Bool { files.allSatisfy { $0.upload != nil } && (spot == nil || place != nil) }

  public var request: NoteRequest {
    let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return NoteRequest(text: words.isEmpty ? nil : text, date: date, writtenAt: writtenAt,
                       uploads: files.isEmpty ? nil : files.map { UploadRef(upload: $0.upload ?? "", type: $0.type, name: $0.name) },
                       place: place)
  }
}

/// A write waiting to be sent. Its `id` is the request's idempotency key, so
/// sending it again after a lost answer never repeats it.
public struct OutboxItem: Codable, Sendable, Equatable, Identifiable {
  public var id: UUID
  public var operation: OutboxOperation
  public var queuedAt: Date
  public var attempts: Int
  /// Set when Release Notes refused it for good (too long, a day out of
  /// range, changed since it was read). It stays for the owner to fix or
  /// discard; nothing is lost.
  public var refusal: String?
  /// Why it waits, as the last run left it: no connection, a day's limit
  /// reached, Release Notes busy, no room on the phone.
  public var held: String? = nil
  /// The account it was written under (`/v1/me`'s `account`, API 1.4.0):
  /// the app's, or for a share or Siri's note the one the app mirrored into
  /// the App Group. Nil for one an earlier build queued, until that build's
  /// token, still signed in, reads `/v1/me` (`Outbox.stamp`), or one written
  /// with no account known.
  public var account: String? = nil

  public var idempotencyKey: String { id.uuidString.lowercased() }

  /// What Log says of it while it waits to go.
  public var status: String { held ?? (attempts == 0 ? "Sending…" : "Waiting for a connection") }

  /// Files still to post before it can go.
  public var needsUploads: Bool { files.contains { $0.upload == nil } }

  /// The words it carries, for a note or an edit.
  public var text: String? {
    switch operation {
    case .note(let text, _, _), .edit(_, _, let text, _): text
    case .post(let post): post.text
    case .delete, .pins: nil
    }
  }

  /// A new note, which a refusal lets the owner fix and send again.
  public var isNote: Bool {
    switch operation {
    case .note, .post: true
    default: false
    }
  }

  /// The files it carries.
  public var files: [QueuedFile] {
    if case .post(let post) = operation { post.files } else { [] }
  }

  /// Written under another account than the one `recipient` sends for, or
  /// under none known, which may be another's (Jamie, 2026-10-30: "Signing
  /// in to another account with notes still waiting: hold them and ask?",
  /// yes). It is never sent until the owner sends it to this account
  /// (`Outbox.move`) or deletes it. Signed in to its own account again, it
  /// goes as any other.
  public func isHeld(for recipient: OutboxRecipient) -> Bool {
    if case .account(let current) = recipient { account != current } else { false }
  }

  /// Whether it can be sent to another account than the one it was written
  /// under: a new note or pins can, but an edit or a delete changes a note
  /// that account's token wrote, which no other token may change.
  public var canMove: Bool {
    switch operation {
    case .edit, .delete: false
    case .note, .post, .pins: true
    }
  }
}

/// Whose writes a run of the Outbox sends.
public enum OutboxRecipient: Sendable, Equatable {
  /// The account the token signed in now opens (`/v1/me`'s `account`).
  /// Items written under any other, or under none known, are held
  /// (`OutboxItem.isHeld`).
  case account(String)
  /// Every item: a share's own queue, sent as it is written, or a server
  /// from before API 1.4.0, which names no account.
  case anyone
}

/// What Release Notes answered for each kind of write.
public enum OutboxResult: Sendable, Equatable {
  case filed(NoteReceipt)
  case edited(NoteRef)
  case deleted
  case pinned(Tags)
  /// Done (a 2xx), in an answer this build couldn't read.
  case done
}

public struct SentItem: Sendable, Equatable {
  public var item: OutboxItem
  public var result: OutboxResult
}

public struct FlushReport: Sendable, Equatable {
  public var sent: [SentItem] = []
  public var refused: [OutboxItem] = []
  /// Why sending stopped early: offline, rate limited, or signed out. The
  /// rest wait, in order, for the next flush.
  public var stopped: APIError?

  /// The receipts of new notes filed, oldest first.
  public var filed: [NoteReceipt] {
    sent.compactMap { if case .filed(let receipt) = $0.result { receipt } else { nil } }
  }
}

/// The queue could not be written to the phone's storage (full, or
/// protected). The write was not taken, so the caller keeps the words.
public struct OutboxNotKept: Error, Sendable, Equatable {}

/// Every write goes through here, online or not ("never lose a note"). Items
/// are kept as one JSON file in the app's own container, oldest first.
public actor Outbox {
  public typealias Sender = @Sendable (OutboxItem) async throws(APIError) -> OutboxResult
  /// Makes an item ready to send (posts its files, names its place) and
  /// answers it changed; the Outbox saves it before sending, so a resend
  /// carries the same uploads under the same key.
  public typealias Preparer = @Sendable (OutboxItem, URL?) async throws(APIError) -> OutboxItem

  private let file: URL?
  /// Where a queued note's files wait, beside the queue.
  public nonisolated let filesFolder: URL?
  private var items: [OutboxItem]
  private var flushing = false
  /// A share's queue, which the app takes over should its extension be
  /// suspended mid-send for long (`ShareInbox.abandoned`). Once its file is
  /// gone it is the app's, and this queue writes, and so sends, no more.
  private let claimable: Bool
  private var wrote: Bool
  /// The file couldn't be read and couldn't be moved aside either: it is
  /// never written over, so nothing is queued here.
  private let stuck: Bool
  /// Shares taken in, by id, with when, so one its extension closed again
  /// after the app took it (suspended mid-send, then woken) is never taken
  /// in twice, whether its note still waits or went long ago. Kept a month.
  private var adopted: [String: Date]

  /// `file` nil keeps everything in memory (tests, previews). Files wait in
  /// `files`, or else in `outbox-files` beside the queue.
  public init(file: URL?, files: URL? = nil, claimable: Bool = false) {
    self.file = file
    self.filesFolder = files ?? file?.deletingLastPathComponent().appending(path: "outbox-files", directoryHint: .isDirectory)
    self.claimable = claimable
    var items: [OutboxItem] = []
    var stuck = false
    if let file, FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) {
      if let saved = Self.read(file) { items = saved } else { stuck = !SetAside.move(file) }
    }
    // A queue set aside before comes back once it reads (a newer build's,
    // read by a newer build again), ahead of anything queued since.
    if let file, !stuck {
      for aside in SetAside.files(of: file) {
        guard let saved = Self.read(aside) else { continue }
        let known = Set(items.map(\.id))
        let merged = saved.filter { !known.contains($0.id) } + items
        guard (try? Self.write(merged, to: file)) != nil else { continue }
        items = merged
        try? FileManager.default.removeItem(at: aside)
      }
    }
    self.items = items
    self.stuck = stuck
    self.wrote = file.map { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) } ?? false
    self.adopted = Self.adoptedFile(file).flatMap { try? Data(contentsOf: $0) }
      .flatMap { try? JSONDecoder().decode([String: Date].self, from: $0) } ?? [:]
  }

  private static func read(_ file: URL) -> [OutboxItem]? {
    (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([OutboxItem].self, from: $0) }
  }

  private static func adoptedFile(_ file: URL?) -> URL? {
    file.map { $0.deletingLastPathComponent().appending(path: $0.deletingPathExtension().lastPathComponent + "-adopted.json") }
  }

  public var waiting: [OutboxItem] { items }

  /// Queues a write under `account`, the one it is written under, answering
  /// only once it is on disk.
  @discardableResult
  public func enqueue(_ operation: OutboxOperation, account: String? = nil) throws(OutboxNotKept) -> OutboxItem {
    let item = OutboxItem(id: UUID(), operation: operation, queuedAt: .now, attempts: 0, refusal: nil, account: account)
    items.append(item)
    do { try save() } catch {
      items.removeAll { $0.id == item.id }
      throw error
    }
    return item
  }

  /// Queues a new note, stamped with the moment it was typed.
  @discardableResult
  public func enqueue(text: String, date: String? = nil, writtenAt: Date = .now, timeZone: TimeZone = .current,
                      account: String? = nil) throws(OutboxNotKept) -> OutboxItem
  {
    try enqueue(.note(text: text, date: date, writtenAt: Timestamp.string(writtenAt, timeZone: timeZone)), account: account)
  }

  /// Takes in a write queued elsewhere (a share from the share extension)
  /// under its own key, so should both send it, it is still one note. One
  /// already here, or taken in before, is left as it is.
  public func adopt(_ item: OutboxItem) throws(OutboxNotKept) {
    guard !knows(item.id) else { return }
    items.append(item)
    do { try save() } catch {
      items.removeAll { $0.id == item.id }
      throw error
    }
    adopted = adopted.filter { $0.value > .now.addingTimeInterval(-30 * 86400) }
    adopted[item.id.uuidString] = .now
    // Unsaved, it is still queued; only a share closed again after it went
    // could come back.
    if let to = Self.adoptedFile(file), let data = try? JSONEncoder().encode(adopted) {
      try? data.write(to: to, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
  }

  /// Whether `id` waits here or was taken in before.
  public func knows(_ id: UUID) -> Bool {
    items.contains { $0.id == id } || adopted[id.uuidString] != nil
  }

  /// Discarding a write the owner gave up on. Should the file not take the
  /// change, it comes back after a relaunch to be discarded again.
  public func discard(_ id: UUID) {
    let gone = items.first { $0.id == id }?.files ?? []
    items.removeAll { $0.id == id }
    try? save()
    removeFiles(gone)
  }

  /// Where a queued file's bytes are.
  public nonisolated func url(for file: QueuedFile) -> URL? {
    filesFolder?.appending(path: file.fileName)
  }

  /// Keeps a file's bytes in the files folder, ready for a note.
  public nonisolated func keep(_ data: Data, as file: QueuedFile) throws(OutboxNotKept) {
    guard let folder = filesFolder, let url = url(for: file) else { return }
    do {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    } catch {
      throw OutboxNotKept()
    }
  }

  /// Removes files no queued note holds, except `keeping` (the draft's), and
  /// any a queue set aside may hold (all of them, should it not read).
  public func sweep(keeping: Set<UUID> = []) {
    guard let folder = filesFolder,
          let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false)),
          let aside = SetAside.contents(of: file.map(SetAside.files(of:)) ?? []) else { return }
    let held = Set(items.flatMap(\.files).map(\.id)).union(keeping)
    for name in names {
      if let id = UUID(uuidString: String(name.prefix(36))), held.contains(id) || SetAside.names(id, in: aside) { continue }
      try? FileManager.default.removeItem(at: folder.appending(path: name))
    }
  }

  /// Removes files' bytes: a draft's the owner took off, or a sent note's.
  public nonisolated func removeFiles(_ files: [QueuedFile]) {
    for file in files { if let url = url(for: file) { try? FileManager.default.removeItem(at: url) } }
  }

  /// Stamps every item with no account with `account`: items an earlier
  /// build queued, which were written under the token still signed in, read
  /// now for the first time (and shares its extension left, taken in first).
  /// Answers how many, once they are on disk.
  @discardableResult
  public func stamp(unknownWith account: String) throws(OutboxNotKept) -> Int {
    let before = items
    var stamped = 0
    for i in items.indices where items[i].account == nil {
      items[i].account = account
      stamped += 1
    }
    guard stamped > 0 else { return 0 }
    do { try save() } catch {
      items = before
      throw error
    }
    return stamped
  }

  /// "Send to this account": a held item, at the owner's word, becomes
  /// `account`'s and goes under its own key, which that account has never
  /// seen (a receipt is the account's). Its files are posted again, since
  /// an upload is the account's own (`media/<user>/api/`); its place is
  /// only names and the spot, as Here gave them, the same for any account,
  /// and stays, with the business picked. A refusal the other account gave
  /// (its token couldn't add files, say) is that account's: this one is
  /// asked afresh, and refuses it again if it would. An edit or a delete
  /// can't move (`canMove`).
  public func move(_ id: UUID, to account: String) throws(OutboxNotKept) {
    guard let i = items.firstIndex(where: { $0.id == id }), items[i].account != account, items[i].canMove else { return }
    let before = items[i]
    items[i].account = account
    items[i].held = nil
    items[i].refusal = nil
    items[i].attempts = 0
    if case .post(var post) = items[i].operation {
      for f in post.files.indices { post.files[f].upload = nil }
      post.reuploads = 0
      items[i].operation = .post(post)
    }
    do { try save() } catch {
      items[i] = before
      throw error
    }
  }

  /// A refused note or edit, fixed by the owner, goes back in line under a
  /// new key: the old key's receipt belongs to the request that was refused.
  /// A note goes with the files in `keeping` (nil: all it had); the rest
  /// are taken off it and off the phone, so one Release Notes refused (a
  /// token that can't add files) needn't hold back the words. An edit goes
  /// from `revision` (nil: the one it was read at), read again after it
  /// changed somewhere else.
  public func retry(_ id: UUID, text: String, keeping files: Set<UUID>? = nil, revision: String? = nil) throws(OutboxNotKept) {
    guard let i = items.firstIndex(where: { $0.id == id }) else { return }
    let before = items[i]
    var dropped: [QueuedFile] = []
    switch items[i].operation {
    case .note(_, let date, let writtenAt):
      items[i].operation = .note(text: text, date: date, writtenAt: writtenAt)
    case .edit(let date, let note, _, let read):
      items[i].operation = .edit(date: date, id: note, text: text, revision: revision ?? read)
    case .post(var post):
      post.text = text
      if let files {
        dropped = post.files.filter { !files.contains($0.id) }
        post.files.removeAll { !files.contains($0.id) }
      }
      // A refused note leaves its uploads for a day, so they go again as
      // they are (made again once should they be gone). A file never
      // posted whose bytes are no longer on the phone goes; the rest still do.
      post.files.removeAll { file in
        file.upload == nil && (url(for: file).map { !FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) } ?? false)
      }
      post.reuploads = 0
      items[i].operation = .post(post)
    default:
      return
    }
    items[i].id = UUID()
    items[i].refusal = nil
    items[i].attempts = 0
    do { try save() } catch {
      items[i] = before
      throw error
    }
    removeFiles(dropped)
  }

  /// Sends what is waiting for `recipient`, oldest first; an item held for
  /// another account is passed over and left as it is. A refusal sets that
  /// item aside and carries on; anything worth retrying stops the run so
  /// order is kept. Items queued while a run is sending join that run.
  public func flush(for recipient: OutboxRecipient = .anyone, prepare: Preparer? = nil, _ send: Sender) async -> FlushReport {
    // One run at a time: a second caller leaves its items to the run under
    // way, which reads the queue afresh after every send, rather than sending
    // the same item alongside it.
    guard !flushing else { return FlushReport() }
    flushing = true
    defer { flushing = false }
    var report = FlushReport()
    var tried = Set<UUID>()
    // The day's uploads used: notes with files still to post wait, and the
    // rest go on in order. An edit or a delete is always of a note already
    // filed (read back from Release Notes), and pins stand alone, so nothing
    // that goes on can depend on a note held here.
    var filesHeld: APIError?
    sending: while var item = items.first(where: {
      $0.refusal == nil && !tried.contains($0.id) && !(filesHeld != nil && $0.needsUploads) && !$0.isHeld(for: recipient)
    }) {
      tried.insert(item.id)
      // Set once the write itself is asked for: a 2xx then means it was done.
      var asked = false
      do throws(APIError) {
        if let prepare, case .post(let post) = item.operation, !post.ready {
          let ready: OutboxItem
          do throws(APIError) { ready = try await prepare(item, filesFolder) } catch {
            guard error.status == 429, item.needsUploads, let i = items.firstIndex(where: { $0.id == item.id }) else { throw error }
            items[i].attempts += 1
            filesHeld = error
            continue
          }
          // Discarded while its files went up.
          guard let i = items.firstIndex(where: { $0.id == item.id }) else { continue }
          // Saved before sending: from here on, every resend is this request.
          // Unsaved, it doesn't go, or a relaunch would prepare it again and
          // send other uploads under the same key.
          let before = items[i].operation
          items[i].operation = ready.operation
          do { try save() } catch {
            let stopped = APIError(status: 507, code: "not_kept", message: Self.notKept)
            items[i].operation = before
            report.stopped = stopped
            break sending
          }
          item.operation = ready.operation
        }
        asked = true
        sent(item, try await send(item), in: &report)
      } catch {
        // Done, in an answer this build can't read: sent, never refused, or
        // a Fix would file it twice.
        if asked, error.done {
          sent(item, .done, in: &report)
          continue
        }
        // Uploads a note found gone (unused for a day, say) are made again
        // once, under a new key: the old key's request was refused.
        if error.field == "uploads", case .post(var post) = item.operation, post.reuploads == 0,
           let i = items.firstIndex(where: { $0.id == item.id }) {
          post.reuploads += 1
          for f in post.files.indices { post.files[f].upload = nil }
          guard remake(i, as: .post(post)) else {
            report.stopped = APIError(status: 507, code: "not_kept", message: Self.notKept)
            break sending
          }
          continue
        }
        // A day Release Notes won't take (a moment from before the
        // birthday, which the app never learns) files to the day the words
        // were written instead, once, under a new key for the same reason.
        if error.code == "date_out_of_range", let i = items.firstIndex(where: { $0.id == item.id }),
           let undated = items[i].operation.undated {
          guard remake(i, as: undated) else {
            report.stopped = APIError(status: 507, code: "not_kept", message: Self.notKept)
            break sending
          }
          continue
        }
        if error.retryable || error.signedOut {
          if let i = items.firstIndex(where: { $0.id == item.id }) { items[i].attempts += 1 }
          report.stopped = error
          break sending
        }
        if let i = items.firstIndex(where: { $0.id == item.id }) {
          items[i].attempts += 1
          items[i].refusal = error.message
          items[i].held = nil
          report.refused.append(items[i])
        }
        try? save()
      }
    }
    // Each note still waiting says why: the one the run stopped at and those
    // behind it for the same reason, a note with files on a day the uploads
    // are used for that.
    for i in items.indices where items[i].refusal == nil && !items[i].isHeld(for: recipient) {
      if filesHeld != nil, items[i].needsUploads {
        items[i].held = Self.filesHeld
      } else if let stopped = report.stopped {
        items[i].held = Self.held(stopped)
      }
    }
    if !tried.isEmpty { try? save() }
    if report.stopped == nil { report.stopped = filesHeld }
    return report
  }

  private func sent(_ item: OutboxItem, _ result: OutboxResult, in report: inout FlushReport) {
    items.removeAll { $0.id == item.id }
    report.sent.append(SentItem(item: item, result: result))
    // Should the file keep a sent item, it is sent again after a relaunch
    // under its own key, and the receipt answers it: still no second note.
    try? save()
    removeFiles(item.files)
  }

  /// Why an item waits after `error` stopped the run; nil for the token,
  /// which Log tells of itself.
  static func held(_ error: APIError) -> String? {
    switch error.status {
    case 0: "Waiting for a connection"
    case 401: nil
    case 429: "Waiting for today’s limit to reset"
    case 507: "Waiting for room on this phone"
    default: "Waiting for Release Notes"
    }
  }

  static let filesHeld = "Waiting for today’s file limit to reset"

  static let notKept = "This phone couldn't save a note to send. Free up some space and it will try again."

  /// Names a queued note's place from a Here the app had already asked for
  /// when the note was committed, so sending it asks no second time. `place`
  /// nil leaves the place off (no city there, the day's spots used).
  public func name(_ id: UUID, spot: Spot, place: DevicePlace?) {
    guard let i = items.firstIndex(where: { $0.id == id }), case .post(var post) = items[i].operation,
          post.spot == spot, post.place == nil else { return }
    if let place { post.place = place } else { post.spot = nil }
    items[i].operation = .post(post)
    // Unsaved, the note still goes: it asks Here again as it is prepared.
    try? save()
  }

  /// The item at `i` as `operation`, under a new key, saved before it is
  /// sent. Unsaved, it stays as it was and isn't sent: a relaunch would
  /// have the old request refused again and remake it under yet another
  /// key, filing the note twice.
  private func remake(_ i: Int, as operation: OutboxOperation) -> Bool {
    let before = items[i]
    items[i].operation = operation
    items[i].id = UUID()
    do { try save() } catch {
      items[i] = before
      return false
    }
    return true
  }

  private func save() throws(OutboxNotKept) {
    guard let file else { return }
    guard !stuck, !(claimable && wrote && !FileManager.default.fileExists(atPath: file.path(percentEncoded: false))) else {
      throw OutboxNotKept()
    }
    try Self.write(items, to: file)
    wrote = true
  }

  private static func write(_ items: [OutboxItem], to file: URL) throws(OutboxNotKept) {
    do {
      try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      try JSONEncoder().encode(items).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    } catch {
      // Never logged: the queue holds words.
      throw OutboxNotKept()
    }
  }
}

public extension APIClient {
  /// Sends one queued write under its own idempotency key.
  func perform(_ item: OutboxItem) async throws(APIError) -> OutboxResult {
    let key = item.idempotencyKey
    switch item.operation {
    case .note(let text, let date, let writtenAt):
      return .filed(try await createNote(NoteRequest(text: text, date: date, writtenAt: writtenAt), idempotencyKey: key))
    case .edit(let date, let id, let text, let revision):
      return .edited(try await editNote(date: date, id: id, text: text, revision: revision, idempotencyKey: key))
    case .delete(let date, let id):
      try await deleteNote(date: date, id: id, idempotencyKey: key)
      return .deleted
    case .pins(let pinned):
      return .pinned(try await setPinned(pinned, idempotencyKey: key))
    case .post(let post):
      return .filed(try await createNote(post.request, idempotencyKey: key))
    }
  }

  /// Posts a queued note's files and names its place, so it is ready to send.
  /// A place that can't be named (no city for the spot, or the day's 100
  /// spots used) is left off: a note is never held back for its place.
  func prepare(_ item: OutboxItem, files folder: URL?) async throws(APIError) -> OutboxItem {
    guard case .post(var post) = item.operation else { return item }
    for i in post.files.indices where post.files[i].upload == nil {
      let file = post.files[i]
      guard let url = folder?.appending(path: file.fileName),
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))[.size]) as? Int else {
        throw APIError(status: 400, code: "file_missing", message: Self.fileMissing)
      }
      let start = UploadStart(name: file.name, type: file.type, size: size)
      var form = try await startUpload(start)
      do { try await self.post(fileAt: url, name: file.name, to: form) } catch {
        // A form can expire before its file goes (the app suspended between,
        // say): one more with a new form, then the refusal is the note's.
        guard error.code == "upload_refused" else { throw error }
        form = try await startUpload(start)
        try await self.post(fileAt: url, name: file.name, to: form)
      }
      post.files[i].upload = form.upload
      post.files[i].type = form.type
    }
    if let spot = post.spot, post.place == nil {
      do { post.place = try await here(spot).place } catch {
        if error.signedOut || (error.retryable && error.status != 429) { throw error }
        post.spot = nil
      }
    }
    var ready = item
    ready.operation = .post(post)
    return ready
  }
}

public enum Timestamp {
  /// RFC 3339 with the local offset: "2026-10-28T23:58:40-05:00".
  public static func string(_ date: Date, timeZone: TimeZone = .current) -> String {
    date.formatted(Date.ISO8601FormatStyle(timeZoneSeparator: .colon, timeZone: timeZone))
  }
}
