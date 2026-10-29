import Foundation
import Testing
@testable import ChangelogKit

/// The Upcoming requests as `/v1` reads them (the OpenAPI file's
/// UpcomingBatch), with the dev server's kind of fictional dates.
@Suite struct UpcomingTests {
  static func json(_ value: some Encodable) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: APIClient.encoder.encode(value)) as? [String: Any])
  }

  static let entry = UpcomingEntry(
    id: "u-1", revision: 3, next: "2027-06-14", through: "2027-06-21", line: "Lake trip. June 14 - 21.",
    fields: UpcomingFields(kind: .trip, title: "Lake trip", date: "2027-06-14", endDate: "2027-06-21", place: "Duluth, Minnesota",
                           tag: "family"))

  @Test func anAddIsSnakeCaseAndLeavesOutWhatIsNone() throws {
    let body = try Self.json(UpcomingBatch.adding(UpcomingFields(kind: .birthday, title: "Ada", date: "11-04", year: 1990)))
    #expect(Set(body.keys) == ["add"])
    let add = try #require((body["add"] as? [[String: Any]])?.first)
    #expect(add["kind"] as? String == "birthday")
    #expect(add["date"] as? String == "11-04")
    #expect(add["year"] as? Int == 1990)
    #expect(add["reminders"] as? [Int] == [7, 1, 0])
    #expect(add["email"] as? Bool == true)
    #expect(add["end_date"] == nil && add["place"] == nil && add["tag"] == nil)
  }

  @Test func aTripsDefaultsAndItsEndDate() throws {
    let body = try Self.json(UpcomingBatch.adding(Self.entry.fields))
    let add = try #require((body["add"] as? [[String: Any]])?.first)
    #expect(add["end_date"] as? String == "2027-06-21")
    #expect(add["endDate"] == nil)
    #expect(add["place"] as? String == "Duluth, Minnesota")
    #expect(add["reminders"] as? [Int] == [14, 1, 0])
  }

  @Test func changeAndRemoveCarryTheRevision() throws {
    var fields = Self.entry.fields
    fields.email = false
    let change = try Self.json(UpcomingBatch.changing(Self.entry, to: fields))
    let sent = try #require((change["change"] as? [[String: Any]])?.first)
    #expect(sent["id"] as? String == "u-1")
    #expect(sent["revision"] as? Int == 3)
    #expect(sent["email"] as? Bool == false)
    #expect(sent["title"] as? String == "Lake trip")
    #expect(Set(change.keys) == ["change"])

    let remove = try Self.json(UpcomingBatch.removing(Self.entry))
    #expect(remove["remove"] as? [[String: AnyHashable]] == [["id": "u-1", "revision": 3]])
  }

  @Test func aDryRunSaysSo() throws {
    let body = try Self.json(UpcomingBatch.adding(Self.entry.fields, dryRun: true))
    #expect(body["dry_run"] as? Bool == true)
    #expect(try Self.json(UpcomingBatch.adding(Self.entry.fields))["dry_run"] == nil)
  }

  static let list = """
    {"today":"2026-10-29","past_left_out":2,"max_entries":200,"entries":[
      {"id":"u-1","kind":"birthday","title":"Ada","tag":null,"date":"11-04","year":1990,"end_date":null,"place":null,
       "email":true,"reminders":[7,1,0],"revision":1,"next":"2026-11-04","status":"upcoming","line":"Ada turns 36.0.0."},
      {"id":"u-2","kind":"trip","title":"Lake trip","tag":"family","date":"2027-06-14","year":null,"end_date":"2027-06-21",
       "place":"Duluth, Minnesota, United States","email":false,"reminders":[14,1,0],"revision":4,"next":"2027-06-14",
       "through":"2027-06-21","status":"upcoming","line":"Lake trip. June 14 - 21."},
      {"id":"u-3","kind":"launch","title":"Later","date":"2027-01-01","email":true,"reminders":[0],"revision":1,
       "next":"2027-01-01","status":"upcoming","line":"Later."}
    ]}
    """

  @Test func theListReadsAndAKindFromLaterIsLeftOut() async throws {
    StubProtocol.set("upcoming.test", .init(status: 200, body: Self.list))
    let list = try await stubbedClient("upcoming.test").upcoming()
    #expect(list.entries.map(\.id) == ["u-1", "u-2"])
    #expect(list.unreadable == 1)
    #expect(list.pastLeftOut == 2)
    #expect(list.entries[0].fields.year == 1990)
    #expect(list.entries[1].fields.endDate == "2027-06-21")
    #expect(list.entries[1].through == "2027-06-21")
    #expect(list.entries[1].fields.email == false)
    #expect(list.entries[1].revision == 4)
    #expect(StubProtocol.requests("upcoming.test").first?.url?.path == "/v1/upcoming")
  }

  @Test func aSaveGoesUnderItsKey() async throws {
    StubProtocol.set("batch.test", .init(status: 200, body: """
      {"dry_run":false,"added":[{"id":"u-9","kind":"event","title":"Recital","tag":null,"date":"2026-12-05","year":null,
        "end_date":null,"place":null,"email":true,"reminders":[7,1,0],"revision":1,"next":"2026-12-05","status":"upcoming",
        "line":"Recital. December 5."}],"changed":[],"removed":[],"unlocked":[{"key":"roadmap","name":"Roadmap"}]}
      """))
    let saved = try await stubbedClient("batch.test").saveUpcoming(
      .adding(UpcomingFields(kind: .event, title: "Recital", date: "2026-12-05")), idempotencyKey: "k-up")
    #expect(saved.saved?.id == "u-9")
    #expect(saved.unlocked?.first?.name == "Roadmap")
    let request = try #require(StubProtocol.requests("batch.test").first)
    #expect(request.httpMethod == "POST")
    #expect(request.url?.path == "/v1/upcoming/batch")
    #expect(request.value(forHTTPHeaderField: "Idempotency-Key") == "k-up")
    #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
  }

  @Test func aDeleteSendsTheRevisionInTheQuery() async throws {
    StubProtocol.set("udelete.test", .init(status: 204, body: ""))
    try await stubbedClient("udelete.test").deleteUpcoming(id: "u-2", revision: 4, idempotencyKey: "k-del")
    let request = try #require(StubProtocol.requests("udelete.test").first)
    #expect(request.httpMethod == "DELETE")
    #expect(request.url?.path == "/v1/upcoming/u-2")
    #expect(request.url?.query == "revision=4")
    #expect(request.value(forHTTPHeaderField: "Idempotency-Key") == "k-del")
  }

  @Test func aRefusalNamesTheEntryAndTheSentenceDropsIt() async throws {
    StubProtocol.set("urefuse.test", .init(status: 400, body: """
      {"error":{"code":"invalid_request","message":"A trip needs a destination the city search knows, like \\"Zürich\\" or \\"Paris, Texas\\"; other kinds have none. (add[0])","field":"add[0]"}}
      """))
    do {
      _ = try await stubbedClient("urefuse.test").saveUpcoming(.adding(Self.entry.fields), idempotencyKey: "k")
      Issue.record("expected a refusal")
    } catch {
      #expect(error.field == "add[0]")
      #expect(!error.retryable)
      #expect(error.upcomingSentence.hasSuffix("other kinds have none."))
    }
  }

  @Test func aMismatchMeansReadAgain() async throws {
    StubProtocol.set("umismatch.test", .init(status: 409, body: """
      {"error":{"code":"revision_mismatch","message":"That date changed since you read it (change[0]). Read GET /v1/upcoming again and redo the change.","field":"change[0]"}}
      """))
    do {
      try await stubbedClient("umismatch.test").deleteUpcoming(id: "u-2", revision: 1, idempotencyKey: "k")
      Issue.record("expected a mismatch")
    } catch {
      #expect(error.code == "revision_mismatch")
      #expect(!error.retryable)
    }
  }

  @Test func theKeyHoldsForTheSameRequestOnly() {
    var keys = RequestKey<UpcomingBatch>()
    var made = 0
    let make = { () -> String in made += 1; return "k\(made)" }
    let add = UpcomingBatch.adding(Self.entry.fields)
    #expect(keys.key(for: add, make: make) == "k1")
    // Tried again after a lost answer: the same key, so no second date.
    #expect(keys.key(for: add, make: make) == "k1")
    var fields = Self.entry.fields
    fields.title = "Lake week"
    #expect(keys.key(for: .adding(fields), make: make) == "k2")
    keys.reset()
    #expect(keys.key(for: .adding(fields), make: make) == "k3")
  }
}

@Suite struct UpcomingDraftTests {
  @Test func aNewTripTakesATripsReminders() {
    var draft = UpcomingDraft(kind: .birthday, today: "2026-10-29")
    #expect(draft.reminders == [7, 1, 0])
    draft.kind = .trip
    #expect(draft.reminders == [14, 1, 0])
    // Chosen by hand, they stay through a change of kind.
    draft.reminders = [3]
    draft.kind = .event
    #expect(draft.reminders == [3])
  }

  @Test func aBirthdayIsMonthAndDay() throws {
    var draft = UpcomingDraft(kind: .birthday, today: "2026-10-29")
    draft.title = "  Ada  "
    draft.month = 2
    draft.day = 29
    draft.year = 1992
    let fields = try draft.fields().get()
    #expect(fields.date == "02-29")
    #expect(fields.title == "Ada")
    #expect(fields.year == 1992)
    #expect(fields.endDate == nil && fields.place == nil)
    draft.month = 4
    draft.day = 31
    #expect(draft.day == 30)
  }

  @Test func whatThePhoneCanCheck() {
    var draft = UpcomingDraft(kind: .trip, today: "2026-10-29")
    #expect(draft.fields() == .failure(.title))
    draft.title = "Lake trip"
    #expect(draft.fields() == .failure(.place))
    draft.place = "Duluth"
    draft.start = "2027-06-14"
    #expect(draft.end == "2027-06-14")
    draft.end = "2027-06-13"
    #expect(draft.fields() == .failure(.end))
    draft.end = "2027-06-21"
    draft.tag = "#!!"
    #expect(draft.fields() == .failure(.tag))
    draft.tag = "#Up North"
    #expect((try? draft.fields().get())?.tag == "up-north")
    draft.reminders = []
    #expect(draft.fields() == .failure(.reminders))
    draft.reminders = [0, 1, 1, 7]
    #expect((try? draft.fields().get())?.reminders == [7, 1, 0])

    var later = UpcomingDraft(kind: .anniversary, today: "2026-10-29")
    later.title = "Us"
    later.year = 2030
    #expect(later.fields() == .failure(.year))
  }

  @Test func anEditStartsFromTheEntry() throws {
    let draft = UpcomingDraft(entry: UpcomingTests.entry, today: "2026-10-29")
    #expect(draft.start == "2027-06-14")
    #expect(draft.end == "2027-06-21")
    #expect(draft.place == "Duluth, Minnesota")
    #expect(draft.tag == "family")
    let batch = try draft.batch(editing: UpcomingTests.entry).get()
    #expect(batch.change.first?.revision == 3)
    #expect(batch.change.first?.fields == UpcomingTests.entry.fields)
  }

  @Test func aPlaceCheckIsADryRunEvenWithoutATitle() throws {
    var draft = UpcomingDraft(kind: .trip, today: "2026-10-29")
    draft.place = "Paris, Texas"
    let batch = try draft.placeCheck(editing: nil).get()
    #expect(batch.dryRun)
    #expect(batch.add.first?.place == "Paris, Texas")
    #expect(draft.title.isEmpty)
  }
}
