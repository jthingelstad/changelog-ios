import Foundation

/// A note waiting to be sent. Its `id` is the request's idempotency key, so
/// sending it again after a lost answer never makes a second note.
public struct OutboxItem: Codable, Sendable, Equatable, Identifiable {
  public var id: UUID
  public var text: String
  public var date: String?
  public var writtenAt: String
  public var queuedAt: Date
  public var attempts: Int
  /// Set when Release Notes refused the note for good (too long, a day out
  /// of range). It stays for the owner to fix or discard; nothing is lost.
  public var refusal: String?

  public var request: NoteRequest { NoteRequest(text: text, date: date, writtenAt: writtenAt) }
  public var idempotencyKey: String { id.uuidString.lowercased() }
}

public struct SentNote: Sendable, Equatable {
  public var item: OutboxItem
  public var receipt: NoteReceipt
}

public struct FlushReport: Sendable, Equatable {
  public var sent: [SentNote] = []
  public var refused: [OutboxItem] = []
  /// Why sending stopped early: offline, rate limited, or signed out. The
  /// rest wait, in order, for the next flush.
  public var stopped: APIError?
}

/// Every note goes through here, online or not ("never lose a note"). Items
/// are kept as one JSON file in the app's own container, oldest first.
public actor Outbox {
  public typealias Sender = @Sendable (OutboxItem) async throws(APIError) -> NoteReceipt

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

  @discardableResult
  public func enqueue(text: String, date: String? = nil, writtenAt: Date = .now, timeZone: TimeZone = .current) -> OutboxItem {
    let item = OutboxItem(
      id: UUID(), text: text, date: date,
      writtenAt: Timestamp.string(writtenAt, timeZone: timeZone),
      queuedAt: .now, attempts: 0, refusal: nil)
    items.append(item)
    save()
    return item
  }

  public func discard(_ id: UUID) {
    items.removeAll { $0.id == id }
    save()
  }

  /// A refused note, edited by the owner, goes back in line under a new key:
  /// the old key's receipt belongs to the request that was refused.
  public func retry(_ id: UUID, text: String) {
    guard let i = items.firstIndex(where: { $0.id == id }) else { return }
    items[i].id = UUID()
    items[i].text = text
    items[i].refusal = nil
    items[i].attempts = 0
    save()
  }

  /// Sends what is waiting, oldest first. A refusal sets that note aside and
  /// carries on; anything worth retrying stops the run so order is kept.
  public func flush(_ send: Sender) async -> FlushReport {
    // One run at a time: a second caller waits for the next one, rather than
    // sending the same note alongside (its key would make that a replay).
    guard !flushing else { return FlushReport() }
    flushing = true
    defer { flushing = false }
    var report = FlushReport()
    for item in items where item.refusal == nil {
      do {
        let receipt = try await send(item)
        items.removeAll { $0.id == item.id }
        report.sent.append(SentNote(item: item, receipt: receipt))
        save()
      } catch {
        if error.retryable || error.signedOut {
          bump(item.id)
          report.stopped = error
          break
        }
        if let i = items.firstIndex(where: { $0.id == item.id }) {
          items[i].attempts += 1
          items[i].refusal = error.message
          report.refused.append(items[i])
        }
        save()
      }
    }
    return report
  }

  private func bump(_ id: UUID) {
    if let i = items.firstIndex(where: { $0.id == id }) { items[i].attempts += 1 }
    save()
  }

  private func save() {
    guard let file else { return }
    do {
      try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      try JSONEncoder().encode(items).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    } catch {
      // Kept in memory until the next save; never logged, it holds words.
    }
  }
}

public enum Timestamp {
  /// RFC 3339 with the local offset: "2026-10-28T23:58:40-05:00".
  public static func string(_ date: Date, timeZone: TimeZone = .current) -> String {
    date.formatted(Date.ISO8601FormatStyle(timeZoneSeparator: .colon, timeZone: timeZone))
  }
}
