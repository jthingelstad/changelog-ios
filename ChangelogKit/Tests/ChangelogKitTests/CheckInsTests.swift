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
}
