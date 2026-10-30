import Foundation

/// The note being written in Log's box, kept so it outlives the app: iOS
/// may end Changelog while the person is in another app (the Camera, say),
/// and the words, files and place are there again on the next launch.
public struct Draft: Codable, Sendable, Equatable {
  public var text: String
  /// Files on the draft, their bytes beside the queue.
  public var files: [QueuedFile]
  /// Where the draft was written, and the place Release Notes named for it.
  public var spot: Spot?
  public var here: Here?
  /// A business nearby the owner picked.
  public var venue: String?
  public var spotAt: Date?
  /// The owner left the place off this draft.
  public var placeOff: Bool
  /// Set as the draft is committed, until the note is in the queue.
  public var handover: Handover?

  /// The note a commit is putting in the queue, by its words and the moment
  /// stamped on it. Should the app end before the draft kept is cleared,
  /// the next launch finds that note in the queue and leaves the draft
  /// there, rather than putting the same words back in the box to be sent
  /// twice.
  public struct Handover: Codable, Sendable, Equatable {
    /// The words as queued, with the sticky tag.
    public var text: String
    public var writtenAt: String

    public init(text: String, writtenAt: String) {
      self.text = text
      self.writtenAt = writtenAt
    }

    /// The queued note this draft became.
    func became(_ item: OutboxItem) -> Bool {
      switch item.operation {
      case .note(let queued, _, let stamp): queued == text && stamp == writtenAt
      case .post(let post): post.text == text && post.writtenAt == writtenAt
      case .edit, .delete, .pins: false
      }
    }
  }

  public init(text: String = "", files: [QueuedFile] = [], spot: Spot? = nil, here: Here? = nil, venue: String? = nil,
              spotAt: Date? = nil, placeOff: Bool = false, handover: Handover? = nil) {
    self.text = text
    self.files = files
    self.spot = spot
    self.here = here
    self.venue = venue
    self.spotAt = spotAt
    self.placeOff = placeOff
    self.handover = handover
  }

  /// No words, files or place: nothing to keep.
  public var isEmpty: Bool {
    text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && files.isEmpty && spot == nil
  }
}

/// Where the draft is kept: one file beside the queue, in the app's own
/// container and protected as the queue is. Never the App Group, so no
/// widget or extension reads it, and never logged.
public struct DraftStore: Sendable {
  public let file: URL?

  /// `file` nil keeps nothing (tests, previews).
  public init(file: URL?) {
    self.file = file
  }

  /// The draft kept, with any file whose bytes are no longer beside the
  /// queue left off; nil when there is none. A draft whose commit reached
  /// the queue before the app ended is that note now, so it is removed.
  public func load(filesIn outbox: Outbox) async -> Draft? {
    guard let file, let data = try? Data(contentsOf: file), var draft = try? JSONDecoder().decode(Draft.self, from: data) else {
      return nil
    }
    if let handover = draft.handover {
      if await outbox.waiting.contains(where: handover.became) {
        remove(file)
        return nil
      }
      // The commit never reached the queue: the words go back in the box.
      draft.handover = nil
    }
    draft.files.removeAll { kept in
      outbox.url(for: kept).map { !FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) } ?? true
    }
    return draft
  }

  /// Keeps the draft, or once it is empty, removes what was kept. False
  /// when the phone couldn't write it; the box still has it, and what was
  /// kept before is removed, so a launch never brings back words already
  /// sent.
  @discardableResult
  public func save(_ draft: Draft) -> Bool {
    guard let file else { return true }
    if draft.isEmpty { return remove(file) }
    do {
      try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      try JSONEncoder().encode(draft).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
      return true
    } catch {
      remove(file)
      return false
    }
  }

  @discardableResult
  private func remove(_ file: URL) -> Bool {
    let manager = FileManager.default
    guard manager.fileExists(atPath: file.path(percentEncoded: false)) else { return true }
    return (try? manager.removeItem(at: file)) != nil
  }
}
