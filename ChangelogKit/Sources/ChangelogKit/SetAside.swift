import Foundation

/// A queue or a share this build couldn't read (written by a newer build, or
/// damaged), moved aside rather than written over or removed, so a later
/// build or a person can still recover it. It keeps its old name in front:
/// `outbox.json.1a2b3c4d.unreadable`. The queue and the share inbox take one
/// back once it reads, and leave the files it may name.
enum SetAside {
  static let suffix = ".unreadable"

  /// Moves `file` aside; false if even that failed, and it is where it was.
  @discardableResult
  static func move(_ file: URL) -> Bool {
    let stamp = UUID().uuidString.lowercased().prefix(8)
    let aside = file.deletingLastPathComponent().appending(path: "\(file.lastPathComponent).\(stamp)\(suffix)")
    return (try? FileManager.default.moveItem(at: file, to: aside)) != nil
  }

  /// What was set aside from `file`, oldest name first.
  static func files(of file: URL) -> [URL] {
    let folder = file.deletingLastPathComponent()
    let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? []
    return names.filter { $0.hasPrefix(file.lastPathComponent + ".") && $0.hasSuffix(suffix) }.sorted()
      .map { folder.appending(path: $0) }
  }

  /// The bytes of each, or nil when one can't be read: then any file may be
  /// one it names.
  static func contents(of files: [URL]) -> [Data]? {
    var all: [Data] = []
    for file in files {
      guard let data = try? Data(contentsOf: file) else { return nil }
      all.append(data)
    }
    return all
  }

  /// Whether a queued file's id is in what was set aside. A queue names a
  /// file by its id, which nothing else has, so the bytes are searched
  /// without being read as a queue.
  static func names(_ id: UUID, in contents: [Data]) -> Bool {
    let upper = Data(id.uuidString.uppercased().utf8), lower = Data(id.uuidString.lowercased().utf8)
    return contents.contains { $0.range(of: upper) != nil || $0.range(of: lower) != nil }
  }
}
