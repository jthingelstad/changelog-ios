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

  /// Each note's words, by id, as read now. A note gone since (404) or no
  /// longer this token's (403) drops out; any other failure, offline
  /// included, keeps what was read before. Notes not asked about drop out.
  public static func read(
    _ notes: [Note],
    keeping before: [String: String],
    using fetch: @escaping @Sendable (Note) async throws(APIError) -> String
  ) async -> [String: String] {
    var seen = Set<Note>()
    let asked = Array(notes.filter { seen.insert($0).inserted }.prefix(limit))
    var words = before.filter { id, _ in asked.contains { $0.id == id } }
    await withTaskGroup(of: (String, Result<String, APIError>).self) { group in
      for note in asked {
        group.addTask {
          do throws(APIError) { return (note.id, .success(try await fetch(note))) } catch { return (note.id, .failure(error)) }
        }
      }
      for await (id, answer) in group {
        switch answer {
        case .success(let text): words[id] = text
        case .failure(let error) where error.status == 404 || error.status == 403: words[id] = nil
        case .failure: break
        }
      }
    }
    return words
  }
}
