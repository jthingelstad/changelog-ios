import Foundation
import Testing
@testable import ChangelogKit

@Suite struct CheckInsTests {
  static let chicago = TimeZone(identifier: "America/Chicago")!
  static let arrival = Date(timeIntervalSince1970: 1_793_000_000)

  /// DateFormatter's times carry a narrow space before AM and PM.
  static func plain(_ words: String?) -> String? { words?.replacingOccurrences(of: "\u{202F}", with: " ") }

  // MARK: Reports

  @Test func iOSsUnknownTimesAreLeftOut() throws {
    let arriving = try #require(CheckInReport.visit(arrival: Self.arrival, departure: .distantFuture, lat: 44.97, lon: -93.26,
                                                    accuracy: 50, timeZone: Self.chicago))
    #expect(arriving.arrived != nil && arriving.left == nil)
    #expect(arriving.source == "visit" && arriving.timeZone == "America/Chicago" && arriving.accuracyM == 50)
    let leaving = try #require(CheckInReport.visit(arrival: .distantPast, departure: Self.arrival, lat: 44.97, lon: -93.26,
                                                   accuracy: 50, timeZone: Self.chicago))
    #expect(leaving.arrived == nil && leaving.left != nil)
  }

  @Test func aVisitWithNeitherTimeIsNotReported() {
    #expect(CheckInReport.visit(arrival: .distantPast, departure: .distantFuture, lat: 44.97, lon: -93.26, accuracy: 50) == nil)
  }

  @Test func aNegativeAccuracyIsNoAccuracy() throws {
    let report = try #require(CheckInReport.visit(arrival: Self.arrival, departure: .distantFuture, lat: 44.97, lon: -93.26, accuracy: -1))
    #expect(report.accuracyM == nil)
  }

  /// A later report of the stay fills it in by source and arrival to the
  /// second, so the two reports of a visit have to agree on how it's written.
  @Test func anArrivalAndItsLeavingWriteTheSameArrival() throws {
    let first = try #require(CheckInReport.visit(arrival: Self.arrival, departure: .distantFuture, lat: 44.97, lon: -93.26, accuracy: 50))
    let second = try #require(CheckInReport.visit(arrival: Self.arrival, departure: Self.arrival.addingTimeInterval(600), lat: 44.97, lon: -93.26, accuracy: 20))
    #expect(first.arrived == second.arrived)
  }

  @Test func aTapIsTheMomentAndNothingMore() {
    let report = CheckInReport.tap(at: Self.arrival, spot: Spot(lat: 44.97, lon: -93.26, accuracyM: 12), timeZone: Self.chicago)
    #expect(report.source == "tap" && report.left == nil && report.arrived != nil && report.accuracyM == 12)
  }

  // MARK: The queue

  @Test func aReportWaitsItsTurnAndHasNoText() async throws {
    let outbox = Outbox(file: nil)
    let report = CheckInReport.tap(at: Self.arrival, spot: Spot(lat: 44.97, lon: -93.26, accuracyM: 12))
    let item = try await outbox.enqueue(.checkIn(report))
    #expect(item.text == nil && item.isCheckIn && item.isTap && !item.isNote)
    #expect(item.canMove)
    let flushed = await outbox.flush { (_) async throws(APIError) -> OutboxResult in .done }
    #expect(flushed.sent.count == 1)
  }

  @Test func aVisitInTheQueueIsNotATap() throws {
    let report = try #require(CheckInReport.visit(arrival: Self.arrival, departure: .distantFuture, lat: 44.97, lon: -93.26, accuracy: 50))
    let item = OutboxItem(id: UUID(), operation: .checkIn(report), queuedAt: Self.arrival, attempts: 0)
    #expect(item.isCheckIn && !item.isTap)
  }

  /// A report kept in the queue file reads back after the app is gone.
  @Test func aReportSurvivesTheQueueFile() async throws {
    let file = FileManager.default.temporaryDirectory.appending(path: "checkins-\(UUID().uuidString)/outbox.json")
    let report = CheckInReport(arrived: "2026-11-06T15:00:00Z", left: nil, lat: 44.97, lon: -93.26, accuracyM: 40,
                               timeZone: "America/Chicago", source: "visit")
    try await Outbox(file: file).enqueue(.checkIn(report))
    let again = Outbox(file: file)
    let waiting = await again.waiting
    #expect(waiting.count == 1)
    guard case .checkIn(let read) = waiting.first?.operation else { Issue.record("not a check-in"); return }
    #expect(read == report)
  }

  // MARK: The name

  /// Taking a name off has to send null: a missing name is a 400.
  @Test func takingANameOffSendsNull() throws {
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    let off = try JSONSerialization.jsonObject(with: encoder.encode(CheckInNaming(name: nil, revision: 3))) as? [String: Any]
    #expect(off?["name"] is NSNull)
    #expect(off?["revision"] as? Int == 3)
    let on = try JSONSerialization.jsonObject(with: encoder.encode(CheckInNaming(name: "Workshop", revision: 3))) as? [String: Any]
    #expect(on?["name"] as? String == "Workshop")
  }

  @Test func anOwnNameAndAPlaceAreNamedANeighbourhoodIsNot() throws {
    func stay(_ namedBy: String) throws -> CheckIn {
      try APIClient.decoder.decode(CheckIn.self, from: Data("""
      {"id":"a","at":"2026-11-06T15:00:00Z","day":"2026-11-06","lat":44.97,"lon":-93.26,"source":"visit","revision":1,"label":"Somewhere","named_by":"\(namedBy)"}
      """.utf8))
    }
    #expect(try stay("own").isNamed && stay("place").isNamed)
    #expect(try !stay("district").isNamed && !stay("none").isNamed)
  }

  @Test func aStayAnswersToAnyOfItsIds() throws {
    let stay = try APIClient.decoder.decode(CheckIn.self, from: Data("""
    {"id":"a","ids":["a","b"],"at":"2026-11-06T15:00:00Z","day":"2026-11-06","lat":44.97,"lon":-93.26,"source":"visit","revision":1,"label":"Somewhere","named_by":"none"}
    """.utf8))
    #expect(stay.answers(to: "a") && stay.answers(to: "b") && !stay.answers(to: "c"))
  }

  // MARK: Words

  @Test func aStaySaysHowLongItLasted() {
    let words = CheckInWords.stay(arrived: "2026-11-06T15:05:00Z", left: "2026-11-06T16:15:00Z", source: "visit", timeZone: Self.chicago,
                                  locale: Locale(identifier: "en_US"))
    #expect(Self.plain(words) == "9:05 AM to 10:15 AM, 70 min")
  }

  @Test func aStayStillGoingAndATapSayWhen() {
    let locale = Locale(identifier: "en_US")
    #expect(Self.plain(CheckInWords.stay(arrived: "2026-11-06T15:05:00Z", left: nil, source: "visit", timeZone: Self.chicago, locale: locale)) == "Since 9:05 AM")
    #expect(Self.plain(CheckInWords.stay(arrived: "2026-11-06T15:05:00Z", left: nil, source: "tap", timeZone: Self.chicago, locale: locale)) == "At 9:05 AM")
    #expect(Self.plain(CheckInWords.stay(arrived: nil, left: "2026-11-06T15:05:00Z", source: "visit", timeZone: Self.chicago, locale: locale)) == "Until 9:05 AM")
  }

  /// In the zone it happened in, wherever the phone is now.
  @Test func aStayReadsInItsOwnZone() {
    let words = CheckInWords.stay(arrived: "2026-11-06T15:05:00Z", left: nil, source: "tap", timeZone: TimeZone(identifier: "Asia/Tokyo")!,
                                  locale: Locale(identifier: "en_US"))
    #expect(Self.plain(words) == "At 12:05 AM")
  }

  @Test func anUnnamedStopSaysSo() {
    #expect(CheckInWords.stopName(nil) == "an unnamed stop")
    #expect(CheckInWords.stopName("Unnamed stop") == "an unnamed stop")
    #expect(CheckInWords.stopName("Workshop") == "Workshop")
  }

  @Test func timesReadWithOrWithoutFractions() {
    #expect(CheckInWords.date("2026-11-06T15:05:00Z") != nil)
    #expect(CheckInWords.date("2026-11-06T15:05:00.123Z") != nil)
    #expect(CheckInWords.date("yesterday") == nil)
  }

  // MARK: The row

  static func row(_ json: String) throws -> ActivityItem {
    try APIClient.decoder.decode(ActivityItem.self, from: Data(json.utf8))
  }

  @Test func aTapsRowSaysAtAndOpensItsStay() throws {
    let item = try Self.row("""
    {"id":"e1","kind":"checkin","at":"2026-11-06T15:05:00Z","day":"2026-11-06","checkin":"c1","label":"Workshop","arrived":"2026-11-06T15:05:00Z","source":"tap","time_zone":"America/Chicago","via":"token","token":"Changelog"}
    """)
    #expect(item.checkin == "c1" && item.label == "Workshop" && item.source == "tap")
    #expect(item.opens == .checkIn(day: "2026-11-06", id: "c1"))
    #expect(item.stayLine?.hasPrefix("At ") == true)
    #expect(item.detail?.contains("Changelog") == true)
  }

  @Test func aDeletedStopOpensNothingAndCarriesItsCount() throws {
    let item = try Self.row("""
    {"id":"e2","kind":"checkin.deleted","at":"2026-11-06T15:05:00Z","all":true,"count":4}
    """)
    #expect(item.opens == nil && item.all == true && item.count == 4)
  }

  /// `source` on a row is the check-in's, and how anything came is `channel`.
  @Test func aNotesRowStillSaysHowItCame() throws {
    let item = try Self.row("""
    {"id":"e3","kind":"note","at":"2026-11-06T15:05:00Z","day":"2026-11-06","via":"email"}
    """)
    #expect(item.source == nil && item.channel != nil)
  }

  // MARK: Ignored places (API 1.20.0)

  static let stayJSON = """
    {"id":"c-1","at":"2026-11-08T15:00:00Z","day":"2026-11-08","arrived":"2026-11-08T15:00:00Z","left":null,"lat":44.97,"lon":-93.26,"source":"tap","revision":1,"label":"Home","named_by":"place","place":"p-1"}
    """

  @Test func aPlaceFromBefore1_20IsNotIgnored() throws {
    let old = try APIClient.decoder.decode(RememberedPlace.self, from: Data("""
      {"id":"p-1","name":"Home","spots":[{"lat":44.97,"lon":-93.26}],"revision":2}
      """.utf8))
    #expect(!old.ignored && old.checkIns == nil && old.spots.count == 1)
    let ignored = try APIClient.decoder.decode(RememberedPlace.self, from: Data("""
      {"id":"p-1","name":"Home","spots":[{"lat":44.97,"lon":-93.26}],"revision":3,"ignored":true}
      """.utf8))
    #expect(ignored.ignored)
  }

  @Test func onePlaceReadSaysHowManyCheckInsAreThere() async throws {
    StubProtocol.set("place-count.test", .init(status: 200, body: """
      {"place":{"id":"p-1","name":"Home","spots":[{"lat":44.97,"lon":-93.26}],"revision":3,"ignored":true,"check_ins":7}}
      """))
    let place = try await stubbedClient("place-count.test").rememberedPlace(id: "p-1")
    #expect(place.checkIns == 7 && place.ignored)
    let request = try #require(StubProtocol.requests("place-count.test").first)
    #expect(request.httpMethod == "GET" && request.url?.path == "/v1/check-ins/places/p-1")
  }

  @Test func ignoringAPlaceSendsOnlyIgnored() async throws {
    StubProtocol.set("ignore.test", .init(status: 200, body: """
      {"place":{"id":"p-1","name":"Home","spots":[{"lat":44.97,"lon":-93.26}],"revision":4,"ignored":true}}
      """))
    let place = try await stubbedClient("ignore.test").setPlaceIgnored(id: "p-1", ignored: true, idempotencyKey: "k-1")
    #expect(place.ignored && place.revision == 4)
    let request = try #require(StubProtocol.requests("ignore.test").first)
    #expect(request.httpMethod == "PATCH" && request.url?.path == "/v1/check-ins/places/p-1")
    #expect(request.value(forHTTPHeaderField: "Idempotency-Key") == "k-1")
    let body = try JSONSerialization.jsonObject(with: try #require(request.httpBody)) as? [String: Bool]
    #expect(body == ["ignored": true])
  }

  @Test func aReportFromBefore1_20WasKept() throws {
    let old = try APIClient.decoder.decode(CheckInReceipt.self, from: Data(#"{"check_in":\#(Self.stayJSON)}"#.utf8))
    #expect(old.kept && old.ignoredAt == nil && old.checkIn.id == "c-1")
    let kept = try APIClient.decoder.decode(CheckInReceipt.self, from: Data(#"{"check_in":\#(Self.stayJSON),"kept":true}"#.utf8))
    #expect(kept.kept)
  }

  @Test func aReportAtAnIgnoredPlaceWasNotKept() throws {
    let receipt = try APIClient.decoder.decode(CheckInReceipt.self, from: Data(#"{"check_in":\#(Self.stayJSON),"kept":false}"#.utf8))
    #expect(!receipt.kept && receipt.ignoredAt == "Home")
    // A token that isn't told the place's name.
    let unnamed = Self.stayJSON.replacingOccurrences(of: #""label":"Home","named_by":"place","place":"p-1""#,
                                                     with: #""label":"Unnamed stop","named_by":"none""#)
    let quiet = try APIClient.decoder.decode(CheckInReceipt.self, from: Data(#"{"check_in":\#(unnamed),"kept":false}"#.utf8))
    #expect(!quiet.kept && quiet.ignoredAt == nil)
  }

  /// Not kept is done: it leaves the queue, never to be sent again, and
  /// carries no stay, whose id names nothing.
  @Test func aTapAtAnIgnoredPlaceIsDoneAndCarriesNoStay() async throws {
    StubProtocol.set("not-kept.test", .init(status: 200, body: #"{"check_in":\#(Self.stayJSON),"kept":false}"#))
    let client = stubbedClient("not-kept.test"), outbox = Outbox(file: nil)
    try await outbox.enqueue(.checkIn(.tap(at: Self.arrival, spot: Spot(lat: 44.97, lon: -93.26, accuracyM: 12))))
    let report = await outbox.flush { (item) async throws(APIError) -> OutboxResult in try await client.perform(item) }
    #expect(report.stopped == nil && report.refused.isEmpty)
    #expect(report.sent.map(\.result) == [.notKept(at: "Home")])
    #expect(await outbox.waiting.isEmpty)
    #expect(StubProtocol.requests("not-kept.test").count == 1, "sent once")
    #expect(CheckInWords.notKept(at: "Home") == "Not checked in. You ignore Home, so no check-ins are kept there.")
    #expect(CheckInWords.notKept(at: nil) == "Not checked in. You ignore this place, so no check-ins are kept there.")
  }

  @Test func aTapKeptIsACheckIn() async throws {
    StubProtocol.set("kept.test", .init(status: 201, body: #"{"check_in":\#(Self.stayJSON),"kept":true}"#))
    let item = OutboxItem(id: UUID(), operation: .checkIn(.tap(at: Self.arrival, spot: Spot(lat: 44.97, lon: -93.26, accuracyM: 12))),
                          queuedAt: Self.arrival, attempts: 0)
    guard case .checkedIn(let stay) = try await stubbedClient("kept.test").perform(item) else { Issue.record("not checked in"); return }
    #expect(stay.id == "c-1")
  }

  @Test func deletingAPlacesCheckInsSendsTheCountShown() async throws {
    StubProtocol.set("delete-here.test", .init(status: 200, body: #"{"deleted":3}"#))
    let gone = try await stubbedClient("delete-here.test").deleteCheckIns(atPlace: "p-1", count: 3, idempotencyKey: "k-2")
    #expect(gone == 3)
    let request = try #require(StubProtocol.requests("delete-here.test").first)
    #expect(request.httpMethod == "DELETE" && request.url?.path == "/v1/check-ins/places/p-1/check-ins")
    #expect(request.url?.query == "count=3")
    #expect(request.value(forHTTPHeaderField: "Idempotency-Key") == "k-2")
  }

  @Test func anotherCountIsRefusedWithTheCountNow() async throws {
    StubProtocol.set("delete-count.test", .init(status: 409, body: """
      {"error":{"code":"revision_mismatch","message":"The check-ins there changed since you counted them. GET /v1/check-ins/places/{id} again for the count.","count":5}}
      """))
    do {
      _ = try await stubbedClient("delete-count.test").deleteCheckIns(atPlace: "p-1", count: 3, idempotencyKey: "k-3")
      Issue.record("expected a refusal")
    } catch {
      #expect(error.status == 409 && error.code == "revision_mismatch")
      #expect(error.count == 5)
      #expect(!error.retryable)
    }
  }

  /// A check-in's revision is a number: its refusal still reads whole.
  @Test func aCheckInsNumberRevisionStillReads() async throws {
    StubProtocol.set("stay-revision.test", .init(status: 409, body: """
      {"error":{"code":"revision_mismatch","message":"That check-in changed since you read it. Read it again.","revision":3}}
      """))
    do {
      _ = try await stubbedClient("stay-revision.test").nameCheckIn(id: "c-1", name: "Workshop", revision: 2, idempotencyKey: "k-4")
      Issue.record("expected a refusal")
    } catch {
      #expect(error.code == "revision_mismatch" && error.revision == "3")
      #expect(error.message == "That check-in changed since you read it. Read it again.")
    }
  }

  @Test func ignoringAndUnignoringReadAsTheWebHasThem() throws {
    let ignored = try Self.row(#"{"id":"e4","kind":"checkin.ignored","at":"2026-11-08T15:05:00Z","place":"p-1","via":"web"}"#)
    #expect(ignored.place == "p-1" && ignored.opens == nil)
    #expect(ignored.checkInHeadline == "Ignored a remembered place")
    #expect(ignored.checkInMore == "Its check-ins are hidden, and no new ones are kept there.")
    let back = try Self.row(#"{"id":"e5","kind":"checkin.unignored","at":"2026-11-08T15:05:00Z","place":"p-1","via":"web"}"#)
    #expect(back.checkInHeadline == "Stopped ignoring a remembered place")
    #expect(back.checkInMore == "Its check-ins show again.")
  }

  @Test func deletingAtAPlaceSaysHowManyWent() throws {
    let some = try Self.row(#"{"id":"e6","kind":"checkin.deleted","at":"2026-11-08T15:05:00Z","place":"p-1","count":3}"#)
    #expect(some.checkInHeadline == "Deleted the check-ins at a remembered place")
    #expect(some.checkInMore == "3 check-ins went.")
    let one = try Self.row(#"{"id":"e7","kind":"checkin.deleted","at":"2026-11-08T15:05:00Z","place":"p-1","count":1}"#)
    #expect(one.checkInMore == "1 check-in went.")
    let day = try Self.row(#"{"id":"e8","kind":"checkin.deleted","at":"2026-11-08T15:05:00Z","day":"2026-11-08","count":1}"#)
    #expect(day.checkInHeadline == "Deleted a check-in" && day.checkInMore == nil)
    let all = try Self.row(#"{"id":"e9","kind":"checkin.deleted","at":"2026-11-08T15:05:00Z","all":true,"count":4}"#)
    #expect(all.checkInHeadline == "Deleted all your check-ins, 4" && all.checkInMore == nil)
  }

  /// A change or a kind this build doesn't know is never worded as another.
  @Test func anUnknownChangeIsNeverForgetting() throws {
    let forgot = try Self.row(#"{"id":"e10","kind":"checkin.place","at":"2026-11-08T15:05:00Z","place":"p-1","change":"forgotten"}"#)
    #expect(forgot.checkInHeadline == "Forgot a remembered place")
    let later = try Self.row(#"{"id":"e11","kind":"checkin.place","at":"2026-11-08T15:05:00Z","place":"p-1","change":"merged"}"#)
    #expect(later.checkInHeadline == "Changed a remembered place")
    let kind = try Self.row(#"{"id":"e12","kind":"checkin.moved","at":"2026-11-08T15:05:00Z"}"#)
    #expect(kind.checkInHeadline == "Changed your check-ins" && kind.checkInMore == nil)
    let note = try Self.row(#"{"id":"e13","kind":"note.added","at":"2026-11-08T15:05:00Z","day":"2026-11-08","note":"n-1"}"#)
    #expect(note.checkInHeadline == nil)
  }

  // MARK: The map

  static func stay(_ id: String, _ label: String, lat: Double, lon: Double = -93.26, place: String? = nil) -> CheckIn {
    CheckIn(id: id, at: "2026-11-06T12:00:00Z", day: "2026-11-06", lat: lat, lon: lon, source: "visit", revision: 1,
            label: label, namedBy: place == nil ? "own" : "place", place: place)
  }

  @Test func stopsAtOneRememberedPlaceAreOnePin() {
    // Far enough apart to need the place: a name can hold a second spot.
    let pins = CheckInMap.pins([Self.stay("c3", "Workshop", lat: 44.97, place: "p-1"),
                                Self.stay("c2", "Bakery", lat: 44.90),
                                Self.stay("c1", "Workshop", lat: 44.98, place: "p-1")])
    #expect(pins.map(\.label) == ["Workshop", "Bakery"])
    #expect(pins[0].stays.map(\.id) == ["c3", "c1"], "newest first")
    #expect(pins[0].id == "c3" && pins[0].lat == 44.97, "the newest stay's spot")
  }

  @Test func oneNameWithin100mIsOnePin() {
    let pins = CheckInMap.pins([Self.stay("c2", "Library", lat: 44.97), Self.stay("c1", "Library", lat: 44.9705)])
    #expect(pins.count == 1 && pins[0].stays.count == 2)
  }

  @Test func oneNameFarApartIsTwoPins() {
    #expect(CheckInMap.pins([Self.stay("c2", "Library", lat: 44.97), Self.stay("c1", "Library", lat: 44.98)]).count == 2)
  }

  @Test func twoShopsNextDoorKeepTheirOwnPins() {
    #expect(CheckInMap.pins([Self.stay("c2", "Bakery", lat: 44.97), Self.stay("c1", "Grocer", lat: 44.9701)]).count == 2)
  }

  @Test func aRememberedPlaceAndAnOwnNameDoNotShareAPin() {
    let pins = CheckInMap.pins([Self.stay("c2", "Workshop", lat: 44.97, place: "p-1"), Self.stay("c1", "Workshop", lat: 44.9701)])
    #expect(pins.count == 2)
  }

  @Test func noStaysNoPins() {
    #expect(CheckInMap.pins([]).isEmpty)
  }

  @Test func metresMatchTheServersWorkingOut() {
    // 0.001 of a degree of latitude, about 111 m.
    #expect(abs(CheckInMap.metres(44.97, -93.26, 44.971, -93.26) - 111.2) < 0.5)
  }
}
