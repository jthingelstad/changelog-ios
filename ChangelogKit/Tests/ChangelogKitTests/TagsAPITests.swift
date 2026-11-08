import Foundation
import Testing
@testable import ChangelogKit

/// Tags through `/v1` (API 1.21.0): a note's, a stay's and a remembered
/// place's, and every tag's totals, read and sent as the OpenAPI file has them.
@Suite struct TagsAPITests {
  static func body(_ request: URLRequest) throws -> [String: Any] {
    let data = try #require(request.httpBody)
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  static func note(_ extra: String) throws -> NoteDetail {
    try APIClient.decoder.decode(NoteDetail.self, from: Data("""
      {"id":"t-1","date":"2026-11-08","text":"At the #lake","revision":"r-1"\(extra)}
      """.utf8))
  }

  // MARK: Notes

  @Test func aNotesTagsReadWithTheirNames() throws {
    let note = try Self.note(#","tags":["road-trip","lake"],"tag_names":["Road Trip","lake"]"#)
    #expect(note.tagList == [Tag(key: "road-trip", name: "Road Trip"), Tag(key: "lake", name: "lake")])
    #expect(note.fieldTags == [Tag(key: "road-trip", name: "Road Trip")])
  }

  /// A server before 1.21.0 sends keys alone: a #word is named as typed, any
  /// other tag by its key.
  @Test func aNoteFromBeforeNamesItsTagsFromItsWords() throws {
    #expect(try Self.note(#","tags":["lake"]"#).tagList == [Tag(key: "lake", name: "lake")])
    let typed = try APIClient.decoder.decode(NoteDetail.self, from: Data("""
      {"id":"t-2","date":"2026-11-08","text":"Back in #Москва","revision":"r-1","tags":["москва"]}
      """.utf8))
    #expect(typed.tagList == [Tag(key: "москва", name: "Москва")])
    #expect(typed.fieldTags.isEmpty)
    #expect(try Self.note("").tagList == [Tag(key: "lake", name: "lake")])
  }

  @Test func anEditSendsItsTagsByNameOrLeavesThemOut() async throws {
    let answer = #"{"note":{"id":"t-1","date":"2026-11-08","version":"4.5.136","revision":"r-2"}}"#
    StubProtocol.set("edit-tags.test", .init(status: 200, body: answer))
    let client = stubbedClient("edit-tags.test")
    _ = try await client.editNote(date: "2026-11-08", id: "t-1", text: "At the lake", revision: "r-1",
                                  tags: ["Road Trip", "🚗"], idempotencyKey: "k-1")
    _ = try await client.editNote(date: "2026-11-08", id: "t-1", text: "At the lake", revision: "r-1", idempotencyKey: "k-2")
    let sent = StubProtocol.requests("edit-tags.test")
    #expect(sent.count == 2)
    #expect(try Self.body(sent[0])["tags"] as? [String] == ["Road Trip", "🚗"])
    #expect(try Self.body(sent[1])["tags"] == nil, "no tags leaves them as they are")
  }

  @Test func aNewNoteSendsItsFieldTags() throws {
    let post = NotePost(text: "Off to the lake", writtenAt: "2026-11-08T09:00:00-06:00", tags: ["Road Trip"])
    let body = try #require(JSONSerialization.jsonObject(with: APIClient.encoder.encode(post.request)) as? [String: Any])
    #expect(body["tags"] as? [String] == ["Road Trip"])
    let none = NotePost(text: "Off to the lake", writtenAt: "2026-11-08T09:00:00-06:00", tags: [])
    #expect(none.tags == nil)
    let bare = try #require(JSONSerialization.jsonObject(with: APIClient.encoder.encode(none.request)) as? [String: Any])
    #expect(bare["tags"] == nil)
  }

  // MARK: The edit sheet

  @Test func aChangeOfTagsAloneIsAnEditWithTheWordsAsTheyAre() throws {
    let note = try Self.note(#","tags":["road-trip","lake"],"tag_names":["Road Trip","lake"]"#)
    // The same tags, by key and name, are no change.
    #expect(NoteChange(note, words: note.text, tags: [Tag(key: "road-trip", name: "Road Trip")]).isEmpty)
    let off = NoteChange(note, words: note.text, tags: [])
    #expect(!off.isEmpty && off.words == nil && off.refusal == nil)
    #expect(off.operations == [.edit(date: "2026-11-08", id: "t-1", text: "At the #lake", revision: "r-1", tags: [])])
    // A respelling is a change: the name is kept as typed.
    let respelled = NoteChange(note, words: note.text, tags: [Tag(key: "road-trip", name: "road trip")])
    #expect(respelled.operations.first == .edit(date: "2026-11-08", id: "t-1", text: "At the #lake", revision: "r-1",
                                                tags: ["road trip"]))
    // Words alone leave the tags as they are.
    #expect(NoteChange(note, words: "At the #lake, swimming").operations.first
            == .edit(date: "2026-11-08", id: "t-1", text: "At the #lake, swimming", revision: "r-1", tags: nil))
  }

  @Test func aNoteWithNoWordsTakesNoTags() throws {
    let note = try APIClient.decoder.decode(NoteDetail.self, from: Data("""
      {"id":"t-3","date":"2026-11-08","text":"","revision":"r-1","files":1}
      """.utf8))
    let change = NoteChange(note, words: "", tags: [Tag(key: "lake", name: "lake")])
    #expect(change.refusal == "Tags go on a note with words. Write some first.")
  }

  /// A queue written before tags keeps its edits: one without `tags` reads
  /// as one that leaves them as they are.
  @Test func anEditQueuedBeforeTagsStillReads() throws {
    let old = #"{"edit":{"date":"2026-11-08","id":"t-1","text":"better","revision":"r-1"}}"#
    let read = try JSONDecoder().decode(OutboxOperation.self, from: Data(old.utf8))
    #expect(read == .edit(date: "2026-11-08", id: "t-1", text: "better", revision: "r-1", tags: nil))
    let now = OutboxOperation.edit(date: "2026-11-08", id: "t-1", text: "better", revision: "r-1", tags: ["Road Trip"])
    #expect(try JSONDecoder().decode(OutboxOperation.self, from: JSONEncoder().encode(now)) == now)
  }

  @Test func aRetriedEditKeepsItsTags() async throws {
    let outbox = Outbox(file: nil)
    let edit = try await outbox.enqueue(.edit(date: "2026-11-08", id: "t-1", text: "At the #lake", revision: "r-1",
                                              tags: ["Road Trip"]))
    let changed = APIError(status: 409, code: "revision_mismatch", message: "That note changed since it was read.", revision: "r-2")
    _ = await outbox.flush { _ throws(APIError) in throw changed }
    try await outbox.retry(edit.id, text: "At the #lake again", revision: "r-2")
    #expect(await outbox.waiting.first?.operation
            == .edit(date: "2026-11-08", id: "t-1", text: "At the #lake again", revision: "r-2", tags: ["Road Trip"]))
  }

  @Test func aDraftFromBeforeTagsHasNone() throws {
    let old = try JSONDecoder().decode(Draft.self, from: JSONEncoder().encode(Draft(text: "half a thought")))
    #expect(old.tags.isEmpty)
    var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(Draft(text: "x"))) as? [String: Any])
    object.removeValue(forKey: "tags")
    let read = try JSONDecoder().decode(Draft.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(read.tags.isEmpty && read.text == "x")
    let kept = Draft(text: "x", tags: [Tag(key: "road-trip", name: "Road Trip")])
    #expect(try JSONDecoder().decode(Draft.self, from: JSONEncoder().encode(kept)).tags == kept.tags)
  }

  // MARK: Check-ins and places

  @Test func aStaysTagsReadWithTheirNames() throws {
    let stay = CheckInsTests.stayJSON.replacingOccurrences(of: #""place":"p-1""#,
                                                           with: #""place":"p-1","tags":["road-trip"],"tag_names":["Road Trip"]"#)
    let read = try APIClient.decoder.decode(CheckIn.self, from: Data(stay.utf8))
    #expect(read.tagList == [Tag(key: "road-trip", name: "Road Trip")])
    #expect(try APIClient.decoder.decode(CheckIn.self, from: Data(CheckInsTests.stayJSON.utf8)).tagList.isEmpty)
  }

  @Test func aPlacesTagsReadAndAreKeptOnlyWhenThere() throws {
    let place = try APIClient.decoder.decode(RememberedPlace.self, from: Data("""
      {"id":"p-1","name":"Cabin","spots":[{"lat":47.9,"lon":-91.8}],"revision":5,"tags":["road-trip","🚗"],"tag_names":["Road Trip","🚗"]}
      """.utf8))
    #expect(place.tags == [Tag(key: "road-trip", name: "Road Trip"), Tag(key: "🚗", name: "🚗")])
    #expect(try APIClient.decoder.decode(RememberedPlace.self, from: APIClient.encoder.encode(place)) == place)
    let bare = RememberedPlace(id: "p-2", name: "Home", spots: [], revision: 1)
    let object = try #require(JSONSerialization.jsonObject(with: APIClient.encoder.encode(bare)) as? [String: Any])
    #expect(object["tags"] == nil && object["tag_names"] == nil)
  }

  @Test func taggingAStaySendsItsWholeListAndNoName() async throws {
    StubProtocol.set("tag-stay.test", .init(status: 200, body: #"{"check_in":\#(CheckInsTests.stayJSON)}"#))
    _ = try await stubbedClient("tag-stay.test").tagCheckIn(id: "c-1", tags: [Tag(key: "road-trip", name: "Road Trip")],
                                                            revision: 1, idempotencyKey: "k-5")
    let request = try #require(StubProtocol.requests("tag-stay.test").first)
    #expect(request.httpMethod == "PATCH" && request.url?.path == "/v1/check-ins/c-1")
    let body = try Self.body(request)
    #expect(body["tags"] as? [String] == ["Road Trip"])
    #expect(body["revision"] as? Int == 1)
    #expect(body.keys.contains("name") == false, "a name sent as null would take the stay's own name off")
  }

  @Test func aPlacesTagsGoAsAWholeList() async throws {
    StubProtocol.set("place-tags.test", .init(status: 200, body: """
      {"place":{"id":"p-1","name":"Cabin","spots":[{"lat":47.9,"lon":-91.8}],"revision":6,"tags":["road-trip"],
       "tag_names":["Road Trip"],"check_ins":4}}
      """))
    let place = try await stubbedClient("place-tags.test").setPlaceTags(id: "p-1", tags: [Tag(key: "road-trip", name: "Road Trip")],
                                                                        idempotencyKey: "k-6")
    #expect(place.checkIns == 4 && place.tags.map(\.name) == ["Road Trip"])
    let request = try #require(StubProtocol.requests("place-tags.test").first)
    #expect(request.httpMethod == "PATCH" && request.url?.path == "/v1/check-ins/places/p-1")
    #expect(try Self.body(request) as? [String: [String]] == ["tags": ["Road Trip"]])
  }

  @Test func taggingAPlacesStaysSendsTheCountShown() async throws {
    StubProtocol.set("tag-here.test", .init(status: 200, body: #"{"tagged":4}"#))
    let tagged = try await stubbedClient("tag-here.test").tagCheckIns(atPlace: "p-1", tags: [Tag(key: "road-trip", name: "Road Trip")],
                                                                      count: 4, idempotencyKey: "k-7")
    #expect(tagged == 4)
    let request = try #require(StubProtocol.requests("tag-here.test").first)
    #expect(request.httpMethod == "PATCH" && request.url?.path == "/v1/check-ins/places/p-1/check-ins")
    let body = try Self.body(request)
    #expect(body["tags"] as? [String] == ["Road Trip"] && body["count"] as? Int == 4)

    StubProtocol.set("tag-count.test", .init(status: 409, body: """
      {"error":{"code":"revision_mismatch","message":"The check-ins there changed since you counted them.","count":6}}
      """))
    do {
      _ = try await stubbedClient("tag-count.test").tagCheckIns(atPlace: "p-1", tags: [Tag(key: "lake", name: "lake")],
                                                                count: 4, idempotencyKey: "k-8")
      Issue.record("expected a refusal")
    } catch {
      #expect(error.code == "revision_mismatch" && error.count == 6)
    }
  }

  @Test func checkInsNarrowToATag() async throws {
    StubProtocol.set("stays-tag.test", .init(status: 200, body: #"{"items":[],"next":null}"#))
    _ = try? await stubbedClient("stays-tag.test").checkIns(tag: "road-trip")
    let request = try #require(StubProtocol.requests("stays-tag.test").first)
    #expect(request.url?.path == "/v1/check-ins")
    let url = try #require(request.url)
    let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    #expect(query.contains(URLQueryItem(name: "tag", value: "road-trip")))
  }

  // MARK: Every tag

  @Test func everyTagReadsWithItsCounts() async throws {
    StubProtocol.set("all-tags.test", .init(status: 200, body: """
      {"tags":[
        {"tag":"road-trip","name":"Road Trip","notes":3,"days":2,"first":"2026-06-01","last":"2026-11-08","upcoming":1,"check_ins":2},
        {"tag":"lake","name":"lake","notes":1,"days":1,"first":"2026-07-04","last":"2026-07-04"},
        {"tag":"house","notes":0,"days":0,"upcoming":2}
      ]}
      """))
    let all = try await stubbedClient("all-tags.test").allTags()
    #expect(all.tags.map(\.named) == [Tag(key: "road-trip", name: "Road Trip"), Tag(key: "lake", name: "lake"),
                                      Tag(key: "house", name: "house")])
    #expect(all.tags[0].checkIns == 2 && all.tags[0].upcoming == 1)
    #expect(all.tags[1].checkIns == nil)
    #expect(StubProtocol.requests("all-tags.test").first?.url?.path == "/v1/tags/all")
  }
}
