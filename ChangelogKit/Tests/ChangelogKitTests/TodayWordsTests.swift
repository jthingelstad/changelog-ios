import Foundation
import Testing
@testable import ChangelogKit

@Suite struct TodayWordsTests {
  private let fixed = TodayWords.Note(date: "2026-10-28", id: "t-1"),
    gone = TodayWords.Note(date: "2026-10-28", id: "t-2"),
    offline = TodayWords.Note(date: "2026-10-28", id: "t-3")

  private static func failing(_ status: Int) -> APIError {
    APIError(status: status, code: status == 0 ? "network" : "x", message: "")
  }

  @Test func readsEachNoteAndKeepsWhatAFailureCannotSay() async {
    let words = await TodayWords.read(
      [fixed, gone, offline],
      keeping: ["t-1": "Old words", "t-2": "Deleted since", "t-3": "Read before", "t-9": "Yesterday's"]
    ) { note throws(APIError) in
      switch note.id {
      case "t-1": return "Fixed the gate #house"
      case "t-2": throw Self.failing(404)
      default: throw Self.failing(0)
      }
    }
    #expect(words == ["t-1": "Fixed the gate #house", "t-3": "Read before"])
  }

  @Test func aNoteNoLongerThisTokensDropsOut() async {
    let words = await TodayWords.read([fixed], keeping: ["t-1": "Mine once"]) { _ throws(APIError) in
      throw Self.failing(403)
    }
    #expect(words.isEmpty)
  }

  @Test func readsEachNoteOnceAndNoMoreThanTheLimit() async {
    let asked = Asked()
    let notes = (0..<30).map { TodayWords.Note(date: "2026-10-28", id: "t-\($0)") }
    let words = await TodayWords.read(notes + notes, keeping: [:]) { note throws(APIError) in
      await asked.add(note.id)
      return "Words of \(note.id)"
    }
    #expect(words.count == TodayWords.limit)
    #expect(await asked.ids.sorted() == notes.prefix(TodayWords.limit).map(\.id).sorted())
  }

  @Test func readsFromTheNotesOwnPath() async throws {
    StubProtocol.set("today-words.test", .init(status: 200, body: """
      {"id":"t-3f9c","date":"2026-10-28","text":"Fixed the gate #house","revision":"9c1e5b0a","written_at":"2026-10-28T07:45:00-05:00"}
      """))
    let client = stubbedClient("today-words.test")
    let words = await TodayWords.read([TodayWords.Note(date: "2026-10-28", id: "t-3f9c")], keeping: [:]) { note throws(APIError) in
      try await client.note(date: note.date, id: note.id).text
    }
    #expect(words == ["t-3f9c": "Fixed the gate #house"])
    let request = try #require(StubProtocol.requests("today-words.test").first)
    #expect(request.httpMethod == "GET")
    #expect(request.url?.path == "/v1/notes/2026-10-28/t-3f9c")
  }
}

private actor Asked {
  var ids: [String] = []
  func add(_ id: String) { ids.append(id) }
}
