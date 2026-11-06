import Foundation
import Testing
@testable import ChangelogKit

@Suite struct VisitsTests {
  static let start = Date(timeIntervalSince1970: 1_793_000_000)

  static func event(arrived: Int?, left: Int?, heard: Int, accuracy: Double = 50, lat: Double = 44.97) -> VisitEvent {
    VisitEvent(heard: start.addingTimeInterval(Double(heard) * 60),
               arrival: arrived.map { start.addingTimeInterval(Double($0) * 60) } ?? .distantPast,
               departure: left.map { start.addingTimeInterval(Double($0) * 60) } ?? .distantFuture,
               lat: lat, lon: -93.26, accuracyM: accuracy, timeZone: "America/Chicago", appState: "background")
  }

  static func log() -> VisitLog {
    VisitLog(url: FileManager.default.temporaryDirectory.appending(path: "visits-\(UUID().uuidString)/visits.jsonl"))
  }

  @Test func iOSsUnknownTimesAreNothing() {
    let event = Self.event(arrived: nil, left: nil, heard: 0)
    #expect(event.arrived == nil && event.left == nil)
  }

  @Test func anArrivalAndItsLeavingAreOneStay() throws {
    let stays = VisitStay.from([Self.event(arrived: 0, left: nil, heard: 3, accuracy: 100),
                                Self.event(arrived: 0, left: 48, heard: 55, accuracy: 40, lat: 44.98)])
    let stay = try #require(stays.first)
    #expect(stays.count == 1)
    #expect(stay.events == 2)
    #expect(stay.minutes == 48)
    #expect(stay.minutesToHearArrival == 3)
    #expect(stay.minutesToHearLeaving == 7)
    #expect(stay.accuracyM == 40 && stay.lat == 44.98)
  }

  /// A departure event must not wipe a leaving already heard, and an arrival
  /// the phone only heard of after leaving wasn't heard on arriving.
  @Test func aStayHeardOnlyAfterLeavingHasNoArrivalDelay() throws {
    let stay = try #require(VisitStay.from([Self.event(arrived: 0, left: 30, heard: 40)]).first)
    #expect(stay.minutesToHearArrival == nil)
    #expect(stay.minutesToHearLeaving == 10)
  }

  @Test func eventsWithNoArrivalStandAloneAndNewestComesFirst() {
    let stays = VisitStay.from([Self.event(arrived: nil, left: 10, heard: 11), Self.event(arrived: nil, left: 90, heard: 91),
                                Self.event(arrived: 100, left: nil, heard: 101)])
    #expect(stays.count == 3)
    #expect(stays.first?.minutesToHearArrival == 1)
  }

  @Test func theSummarySaysWhatWasMeasured() {
    let stays = VisitStay.from([Self.event(arrived: 0, left: 10, heard: 12, accuracy: 30),
                                Self.event(arrived: 100, left: nil, heard: 105, accuracy: 200),
                                Self.event(arrived: 200, left: 260, heard: 264, accuracy: 50)])
    let summary = VisitSummary(stays, calendar: Calendar(identifier: .gregorian))
    #expect(summary.stays == 3)
    #expect(summary.shortestMinutes == 10)
    #expect(summary.medianMinutes == 60)
    #expect(summary.medianAccuracyM == 50)
    #expect(summary.medianMinutesToHearArrival == 5)
    #expect(summary.medianMinutesToHearLeaving == 4)
  }

  @Test func nothingYetMeasuresNothing() {
    let summary = VisitSummary([])
    #expect(summary.stays == 0 && summary.days == 0)
    #expect(summary.shortestMinutes == nil && summary.medianAccuracyM == nil)
  }

  @Test func theLogKeepsEventsInOrderAcrossAppends() throws {
    let log = Self.log()
    let first = Self.event(arrived: 0, left: nil, heard: 1), second = Self.event(arrived: 0, left: 9, heard: 10)
    try log.append(first)
    try VisitLog(url: log.url).append(second)
    #expect(log.read().map(\.id) == [first.id, second.id])
    #expect(log.read().last?.left != nil)
    try log.clear()
    #expect(log.read().isEmpty)
    try log.clear()
  }

  @Test func aLineCutShortIsLeftOut() throws {
    let log = Self.log()
    let event = Self.event(arrived: 0, left: nil, heard: 1)
    try log.append(event)
    let handle = try FileHandle(forWritingTo: log.url)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("{\"id\":\"cut".utf8))
    try handle.close()
    #expect(log.read().map(\.id) == [event.id])
    let next = Self.event(arrived: 0, left: 9, heard: 10)
    try log.append(next)
    #expect(log.read().map(\.id) == [event.id, next.id], "the next visit isn't lost with it")
  }

  @Test func theLogStaysOutOfBackups() throws {
    let log = Self.log()
    try log.append(Self.event(arrived: 0, left: nil, heard: 1))
    #expect(try log.url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
  }
}
