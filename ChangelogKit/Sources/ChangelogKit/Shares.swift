import Foundation

/// What the app and its share extension share: the token's Keychain item,
/// the server and the sticky tag, and notes shared from other apps.
public enum AppGroup {
  public static let id = "group.com.yourversionnumber.changelog"

  /// The group's folder; nil in a build without the App Group (CI, or a
  /// simulator build that isn't signed).
  public static var folder: URL? {
    FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id)
  }

  public static var defaults: UserDefaults? { UserDefaults(suiteName: id) }
}

/// Notes shared from other apps. The share extension keeps each share in a
/// small queue of its own in `shares/`, sends it if it can, and leaves what
/// is left for the app, which adopts it into its Outbox under the same key:
/// a share sent by both is still one note.
public struct ShareInbox: Sendable {
  public let folder: URL

  public init(folder: URL) {
    self.folder = folder
  }

  public static var shared: ShareInbox? {
    AppGroup.folder.map { ShareInbox(folder: $0.appending(path: "shares", directoryHint: .isDirectory)) }
  }

  /// Where shared files wait, for every share.
  public var files: URL { folder.appending(path: "files", directoryHint: .isDirectory) }

  /// A share left mid-send this long ago is taken to have been ended with
  /// its extension.
  public static let abandoned: TimeInterval = 600

  /// A draft open this long is taken to have gone with its extension (the
  /// sheet swiped away), and its files with it.
  public static let draftLife: TimeInterval = 24 * 60 * 60

  /// A new share's queue, while the extension sends it.
  public func open() -> (outbox: Outbox, file: URL) {
    let file = folder.appending(path: UUID().uuidString.lowercased() + ".sending.json")
    return (Outbox(file: file, files: files), file)
  }

  /// Marks `files` as an open draft's, so the sweep leaves them for as
  /// long as the share sheet stays open. Before Commit no queue holds them.
  public func hold(_ files: [QueuedFile], for file: URL) {
    guard let data = try? JSONEncoder().encode(files) else { return }
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try? data.write(to: draft(of: file), options: .atomic)
  }

  /// The draft is committed or cancelled; its files are no longer held by it.
  public func release(_ file: URL) {
    try? FileManager.default.removeItem(at: draft(of: file))
  }

  private func draft(of file: URL) -> URL {
    folder.appending(path: file.lastPathComponent.replacingOccurrences(of: ".sending.json", with: ".draft"))
  }

  /// Hands what the extension couldn't send to the app, or removes the
  /// queue when everything went.
  public func close(_ file: URL, sent: Bool) {
    release(file)
    if sent {
      try? FileManager.default.removeItem(at: file)
    } else {
      let ready = folder.appending(path: file.lastPathComponent.replacingOccurrences(of: ".sending.json", with: ".json"))
      try? FileManager.default.moveItem(at: file, to: ready)
    }
  }

  /// Moves every share the extension finished with into `outbox`, files
  /// and all, keeping each item's key; and any it left mid-send longer ago
  /// than `abandoned`. Answers how many were taken in.
  @discardableResult
  public func adopt(into outbox: Outbox, now: Date = .now) async -> Int {
    let manager = FileManager.default
    guard let names = try? manager.contentsOfDirectory(atPath: folder.path(percentEncoded: false)) else { return 0 }
    var adopted = 0
    for name in names.sorted() where name.hasSuffix(".json") {
      let file = folder.appending(path: name)
      if name.hasSuffix(".sending.json") {
        guard Self.changed(file, or: now) < now.addingTimeInterval(-Self.abandoned) else { continue }
      }
      guard let data = try? Data(contentsOf: file), let items = try? JSONDecoder().decode([OutboxItem].self, from: data) else {
        try? manager.removeItem(at: file)
        continue
      }
      var kept = true
      for item in items {
        let moved = move(item.files, to: outbox)
        do { try await outbox.adopt(item) } catch {
          // The phone is full: the share stays here for the next try.
          move(moved, back: outbox)
          kept = false
          break
        }
        adopted += 1
      }
      if kept { try? manager.removeItem(at: file) }
    }
    sweep(now: now)
    return adopted
  }

  /// Moves a share's files beside the app's queue; answers those moved.
  private func move(_ queued: [QueuedFile], to outbox: Outbox) -> [QueuedFile] {
    let manager = FileManager.default
    guard let folder = outbox.filesFolder else { return [] }
    try? manager.createDirectory(at: folder, withIntermediateDirectories: true)
    var moved: [QueuedFile] = []
    for file in queued {
      let from = files.appending(path: file.fileName)
      guard let to = outbox.url(for: file), !manager.fileExists(atPath: to.path(percentEncoded: false)) else { continue }
      if (try? manager.moveItem(at: from, to: to)) != nil { moved.append(file) }
    }
    return moved
  }

  private func move(_ moved: [QueuedFile], back outbox: Outbox) {
    for file in moved {
      guard let from = outbox.url(for: file) else { continue }
      try? FileManager.default.moveItem(at: from, to: files.appending(path: file.fileName))
    }
  }

  /// Removes shared files no share or open draft holds, once they're old
  /// enough that no extension can still be writing them.
  private func sweep(now: Date) {
    let manager = FileManager.default
    guard let names = try? manager.contentsOfDirectory(atPath: files.path(percentEncoded: false)) else { return }
    var held = Set<String>()
    for name in (try? manager.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? [] {
      let file = folder.appending(path: name)
      if name.hasSuffix(".draft"), Self.changed(file, or: now) < now.addingTimeInterval(-Self.draftLife) {
        try? manager.removeItem(at: file)
        continue
      }
      guard let data = try? Data(contentsOf: file) else { continue }
      if name.hasSuffix(".json"), let items = try? JSONDecoder().decode([OutboxItem].self, from: data) {
        held.formUnion(items.flatMap(\.files).map(\.fileName))
      } else if name.hasSuffix(".draft"), let drafted = try? JSONDecoder().decode([QueuedFile].self, from: data) {
        held.formUnion(drafted.map(\.fileName))
      }
    }
    for name in names where !held.contains(name) {
      let file = files.appending(path: name)
      if Self.changed(file, or: now) < now.addingTimeInterval(-Self.abandoned) { try? manager.removeItem(at: file) }
    }
  }

  private static func changed(_ file: URL, or now: Date) -> Date {
    (try? FileManager.default.attributesOfItem(atPath: file.path(percentEncoded: false))[.modificationDate]) as? Date ?? now
  }
}
