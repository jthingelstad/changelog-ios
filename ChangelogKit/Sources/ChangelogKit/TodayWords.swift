import Foundation

/// The words of today's notes this token wrote, read back one by one for
/// Log's Today (`GET /v1/notes/{date}/{id}`, which `notes:write` allows for
/// a note the token wrote; Jamie, 2026-10-29: "just add the API calls to read
/// what was sent"). The app holds them in memory only: never on disk or in
/// the App Group, and no widget, notification or Siri answer carries them.
public enum TodayWords {
  public struct Note: Hashable, Sendable {
    public var date: String
    public var id: String

    public init(date: String, id: String) {
      self.date = date
      self.id = id
    }
  }

  /// At most this many notes are read on one refresh, the first given.
  public static let limit = 20

  /// Whether a row of Today is a note `token` wrote, the only kind it may
  /// read back, edit or delete: by `token_id` where the row has one, else
  /// by the token's name (`ActivityItem.isBy`).
  public static func isMine(_ item: ActivityItem, token: TokenInfo) -> Bool {
    item.kind == "note.added" && item.note != nil && item.isBy(token)
  }

  /// The notes among Today's rows that `token` wrote, to read back.
  public static func notes(in rows: [ActivityItem], by token: TokenInfo) -> [Note] {
    rows.filter { isMine($0, token: token) }.compactMap { item in
      item.day.flatMap { day in item.note.map { Note(date: day, id: $0) } }
    }
  }

  /// Each note's words, by id, as read now. A note gone since (404) or no
  /// longer this token's (403) drops out; any other failure, offline
  /// included, keeps what was read before. Notes not asked about drop out.
  ///
  /// One task a note, awaited in turn, never a task group: with Swift 6.4
  /// (Xcode 27.1) a task group here, optimized, ends its loop before its
  /// children finish, and a child finishing into the gone group crashed
  /// build 53 on launch (2026-10-30). Debug never did. CI's optimized
  /// `swift test -c release` holds it.
  public static func read(
    _ notes: [Note],
    keeping before: [String: String],
    using fetch: @escaping @Sendable (Note) async throws -> String
  ) async -> [String: String] {
    var seen = Set<Note>()
    let asked = Array(notes.filter { seen.insert($0).inserted }.prefix(limit))
    var words = before.filter { id, _ in asked.contains { $0.id == id } }
    let reads = asked.map { note in
      (note.id, Task { () -> Result<String, any Error> in
        do { return .success(try await fetch(note)) } catch { return .failure(error) }
      })
    }
    for (id, read) in reads {
      switch await read.value {
      case .success(let text): words[id] = text
      case .failure(let error as APIError) where error.status == 404 || error.status == 403: words[id] = nil
      case .failure: break
      }
    }
    return words
  }
}
