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

  public var idempotencyKey: String { id.uuidString.lowercased() }

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
}

/// What Release Notes answered for each kind of write.
public enum OutboxResult: Sendable, Equatable {
  case filed(NoteReceipt)
  case edited(NoteRef)
  case deleted
  case pinned(Tags)
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

  /// `file` nil keeps everything in memory (tests, previews). Files wait in
  /// `files`, or else in `outbox-files` beside the queue.
  public init(file: URL?, files: URL? = nil) {
    self.file = file
    self.filesFolder = files ?? file?.deletingLastPathComponent().appending(path: "outbox-files", directoryHint: .isDirectory)
    if let file, let data = try? Data(contentsOf: file),
       let saved = try? JSONDecoder().decode([OutboxItem].self, from: data) {
      items = saved
    } else {
      items = []
    }
  }

  public var waiting: [OutboxItem] { items }

  /// Queues a write, answering only once it is on disk.
  @discardableResult
  public func enqueue(_ operation: OutboxOperation) throws(OutboxNotKept) -> OutboxItem {
    let item = OutboxItem(id: UUID(), operation: operation, queuedAt: .now, attempts: 0, refusal: nil)
    items.append(item)
    do { try save() } catch {
      items.removeAll { $0.id == item.id }
      throw error
    }
    return item
  }

  /// Queues a new note, stamped with the moment it was typed.
  @discardableResult
  public func enqueue(text: String, date: String? = nil, writtenAt: Date = .now, timeZone: TimeZone = .current)
    throws(OutboxNotKept) -> OutboxItem
  {
    try enqueue(.note(text: text, date: date, writtenAt: Timestamp.string(writtenAt, timeZone: timeZone)))
  }

  /// Takes in a write queued elsewhere (a share from the share extension)
  /// under its own key, so should both send it, it is still one note. One
  /// already here is left as it is.
  public func adopt(_ item: OutboxItem) throws(OutboxNotKept) {
    guard !items.contains(where: { $0.id == item.id }) else { return }
    items.append(item)
    do { try save() } catch {
      items.removeAll { $0.id == item.id }
      throw error
    }
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

  /// Removes files no queued note holds, except `keeping` (the draft's).
  public func sweep(keeping: Set<UUID> = []) {
    guard let folder = filesFolder,
          let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false)) else { return }
    let held = Set(items.flatMap(\.files).map(\.id)).union(keeping)
    for name in names {
      if let id = UUID(uuidString: String(name.prefix(36))), held.contains(id) { continue }
      try? FileManager.default.removeItem(at: folder.appending(path: name))
    }
  }

  /// Removes files' bytes: a draft's the owner took off, or a sent note's.
  public nonisolated func removeFiles(_ files: [QueuedFile]) {
    for file in files { if let url = url(for: file) { try? FileManager.default.removeItem(at: url) } }
  }

  /// A refused note, edited by the owner, goes back in line under a new key:
  /// the old key's receipt belongs to the request that was refused.
  public func retry(_ id: UUID, text: String) throws(OutboxNotKept) {
    guard let i = items.firstIndex(where: { $0.id == id }) else { return }
    let before = items[i]
    switch items[i].operation {
    case .note(_, let date, let writtenAt):
      items[i].operation = .note(text: text, date: date, writtenAt: writtenAt)
    case .post(var post):
      post.text = text
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
  }

  /// Sends what is waiting, oldest first. A refusal sets that item aside and
  /// carries on; anything worth retrying stops the run so order is kept.
  /// Items queued while a run is sending join that run.
  public func flush(prepare: Preparer? = nil, _ send: Sender) async -> FlushReport {
    // One run at a time: a second caller leaves its items to the run under
    // way, which reads the queue afresh after every send, rather than sending
    // the same item alongside it.
    guard !flushing else { return FlushReport() }
    flushing = true
    defer { flushing = false }
    var report = FlushReport()
    var tried = Set<UUID>()
    sending: while var item = items.first(where: { $0.refusal == nil && !tried.contains($0.id) }) {
      tried.insert(item.id)
      do {
        if let prepare, case .post(let post) = item.operation, !post.ready {
          let ready = try await prepare(item, filesFolder)
          // Discarded while its files went up.
          guard let i = items.firstIndex(where: { $0.id == item.id }) else { continue }
          // Saved before sending: from here on, every resend is this request.
          // Unsaved, it doesn't go, or a relaunch would prepare it again and
          // send other uploads under the same key.
          let before = items[i].operation
          items[i].operation = ready.operation
          do { try save() } catch {
            items[i].operation = before
            report.stopped = APIError(status: 507, code: "not_kept", message: Self.notKept)
            break sending
          }
          item.operation = ready.operation
        }
        let result = try await send(item)
        items.removeAll { $0.id == item.id }
        report.sent.append(SentItem(item: item, result: result))
        // Should the file keep a sent item, it is sent again after a relaunch
        // under its own key, and the receipt answers it: still no second note.
        try? save()
        removeFiles(item.files)
      } catch {
        // Uploads a note found gone (unused for a day, say) are made again
        // once, under a new key: the old key's request was refused.
        if error.field == "uploads", case .post(var post) = item.operation, post.reuploads == 0,
           let i = items.firstIndex(where: { $0.id == item.id }) {
          post.reuploads += 1
          for f in post.files.indices { post.files[f].upload = nil }
          items[i].operation = .post(post)
          items[i].id = UUID()
          try? save()
          continue
        }
        if error.retryable || error.signedOut {
          if let i = items.firstIndex(where: { $0.id == item.id }) { items[i].attempts += 1 }
          try? save()
          report.stopped = error
          break sending
        }
        if let i = items.firstIndex(where: { $0.id == item.id }) {
          items[i].attempts += 1
          items[i].refusal = error.message
          report.refused.append(items[i])
        }
        try? save()
      }
    }
    return report
  }

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

  private func save() throws(OutboxNotKept) {
    guard let file else { return }
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
      let form = try await startUpload(UploadStart(name: file.name, type: file.type, size: size))
      try await self.post(fileAt: url, name: file.name, to: form)
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
