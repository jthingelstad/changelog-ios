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
    case .delete, .pins: nil
    }
  }

  /// A new note, which a refusal lets the owner fix and send again.
  public var isNote: Bool {
    if case .note = operation { true } else { false }
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

  private let file: URL?
  private var items: [OutboxItem]
  private var flushing = false

  /// `file` nil keeps everything in memory (tests, previews).
  public init(file: URL?) {
    self.file = file
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

  /// Discarding a write the owner gave up on. Should the file not take the
  /// change, it comes back after a relaunch to be discarded again.
  public func discard(_ id: UUID) {
    items.removeAll { $0.id == id }
    try? save()
  }

  /// A refused note, edited by the owner, goes back in line under a new key:
  /// the old key's receipt belongs to the request that was refused.
  public func retry(_ id: UUID, text: String) throws(OutboxNotKept) {
    guard let i = items.firstIndex(where: { $0.id == id }),
          case .note(_, let date, let writtenAt) = items[i].operation else { return }
    let before = items[i]
    items[i].id = UUID()
    items[i].operation = .note(text: text, date: date, writtenAt: writtenAt)
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
  public func flush(_ send: Sender) async -> FlushReport {
    // One run at a time: a second caller leaves its items to the run under
    // way, which reads the queue afresh after every send, rather than sending
    // the same item alongside it.
    guard !flushing else { return FlushReport() }
    flushing = true
    defer { flushing = false }
    var report = FlushReport()
    var tried = Set<UUID>()
    while let item = items.first(where: { $0.refusal == nil && !tried.contains($0.id) }) {
      tried.insert(item.id)
      do {
        let result = try await send(item)
        items.removeAll { $0.id == item.id }
        report.sent.append(SentItem(item: item, result: result))
        // Should the file keep a sent item, it is sent again after a relaunch
        // under its own key, and the receipt answers it: still no second note.
        try? save()
      } catch {
        if error.retryable || error.signedOut {
          if let i = items.firstIndex(where: { $0.id == item.id }) { items[i].attempts += 1 }
          try? save()
          report.stopped = error
          break
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
    }
  }
}

public enum Timestamp {
  /// RFC 3339 with the local offset: "2026-10-28T23:58:40-05:00".
  public static func string(_ date: Date, timeZone: TimeZone = .current) -> String {
    date.formatted(Date.ISO8601FormatStyle(timeZoneSeparator: .colon, timeZone: timeZone))
  }
}
