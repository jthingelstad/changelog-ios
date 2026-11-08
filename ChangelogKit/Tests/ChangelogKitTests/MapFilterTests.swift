import Foundation
import Testing
@testable import ChangelogKit

/// The map's filters and trails (Jamie, 2026-11-08). Made-up places only.
struct MapFilterTests {
  static func stay(_ id: String, day: String, at: String, lat: Double, lon: Double = -93.26) -> CheckIn {
    CheckIn(id: id, at: at, day: day, lat: lat, lon: lon, source: "visit", revision: 1, label: "Stop \(id)", namedBy: "district")
  }

  static func pin(_ id: String, _ date: String, lat: Double, lon: Double = -93.26, tags: [String] = [],
                  written: String? = nil) -> NotePin {
    NotePin(date: date, id: id, lat: lat, lon: lon, place: "Somewhere", tags: tags, text: "Words \(id)", writtenAt: written)
  }

  let stays = [Self.stay("c3", day: "2026-11-06", at: "2026-11-06T18:00:00Z", lat: 44.9),
               Self.stay("c2", day: "2026-03-01", at: "2026-03-01T15:00:00Z", lat: 44.8),
               Self.stay("c1", day: "2025-12-31", at: "2025-12-31T15:00:00Z", lat: 44.7)]
  let pins = [Self.pin("n1", "2024-07-04", lat: 46.7, tags: ["lake"]),
              Self.pin("n2", "2026-02-01", lat: 46.8),
              Self.pin("n3", "2026-10-10", lat: 46.9, tags: ["lake", "cabin"])]

  @Test func theYearsAreEveryYearWithSomethingNewestFirst() {
    #expect(MapFilter.years(stays, pins) == [2026, 2025, 2024])
    #expect(MapFilter.years([], []).isEmpty)
  }

  @Test func everythingShowsAtFirst() {
    let filter = MapFilter()
    #expect(filter.stays(stays).map(\.id) == ["c3", "c2", "c1"])
    #expect(filter.notes(pins, found: nil).map(\.id) == ["n1", "n2", "n3"])
    #expect(!filter.trails && !filter.narrows)
  }

  @Test func eachKindTurnsOff() {
    #expect(MapFilter(checkIns: false).stays(stays).isEmpty)
    #expect(MapFilter(notes: false).notes(pins, found: nil).isEmpty)
    #expect(MapFilter(notes: false).stays(stays).count == 3)
  }

  @Test func aYearKeepsWhatWasFiledThatYear() {
    let filter = MapFilter(year: 2026)
    #expect(filter.stays(stays).map(\.id) == ["c3", "c2"])
    #expect(filter.notes(pins, found: nil).map(\.id) == ["n2", "n3"])
    #expect(filter.narrows)
  }

  @Test func aTagIsReadFromThePins() {
    let filter = MapFilter(search: .tag("lake"))
    #expect(filter.notes(pins, found: nil).map(\.id) == ["n1", "n3"])
    #expect(MapFilter(year: 2026, search: .tag("lake")).notes(pins, found: nil).map(\.id) == ["n3"])
  }

  @Test func wordsKeepWhatReleaseNotesFound() {
    let filter = MapFilter(search: .words("cabin"))
    #expect(filter.notes(pins, found: nil).isEmpty, "nothing until it answers")
    #expect(filter.notes(pins, found: ["2026-02-01#n2"]).map(\.id) == ["n2"])
    #expect(filter.notes(pins, found: []).isEmpty)
  }

  @Test func wordsKeepNotesAlone() {
    // As on the web's Map: a check-in has no words.
    #expect(MapFilter(search: .words("cabin")).stays(stays).isEmpty)
    #expect(!MapFilter(search: .words("cabin")).keepsCheckIns)
  }

  @Test func aTagKeepsTheCheckInsWithItToo() {
    // Call 8 (Jamie, 2026-11-08): the tag filter keeps notes and check-ins.
    var tagged = stays
    tagged[1].tags = ["lake", "road-trip"]
    tagged[1].tagNames = ["lake", "Road Trip"]
    tagged[2].tags = ["lake"]
    #expect(MapFilter(search: .tag("lake")).stays(tagged).map(\.id) == ["c2", "c1"])
    #expect(MapFilter(year: 2026, search: .tag("lake")).stays(tagged).map(\.id) == ["c2"])
    #expect(MapFilter(search: .tag("cabin")).stays(tagged).isEmpty)
    #expect(MapFilter(checkIns: false, search: .tag("lake")).stays(tagged).isEmpty)
    #expect(MapFilter(search: .tag("lake")).keepsCheckIns)
  }

  @Test func theTagMenuHasEachTagOnceByName() {
    var tagged = stays
    tagged[1].tags = ["road-trip"]
    tagged[1].tagNames = ["Road Trip"]
    let named = [Self.pin("n9", "2026-10-11", lat: 46.9, tags: ["road-trip", "🚗-lake"])]
    var withNames = named
    withNames[0].tagNames = ["road trip", "🚗 Lake"]
    #expect(MapFilter.tags(tagged, pins + withNames).map(\.name) == ["🚗 Lake", "cabin", "lake", "Road Trip"])
    #expect(MapFilter.tags([], []).isEmpty)
  }

  @Test func notesAtOneSpotShareADotNewestFirst() {
    let spots = MapFilter.spots([Self.pin("a", "2026-01-01", lat: 46.7),
                                 Self.pin("b", "2026-01-02", lat: 46.8),
                                 Self.pin("c", "2026-01-03", lat: 46.7)])
    #expect(spots.map { $0.notes.map(\.id) } == [["c", "a"], ["b"]])
    #expect(spots[0].id == "46.7,-93.26")
  }

  @Test func theCheckInTrailRunsInTheOrderTheStopsBegan() {
    let trail = MapFilter.trail(stays)
    #expect(trail.map(\.lat) == [44.7, 44.8, 44.9])
  }

  @Test func aTrailStaysPutForAReturnToTheSameSpot() {
    let again = [Self.stay("c3", day: "2026-11-06", at: "2026-11-06T18:00:00Z", lat: 44.9),
                 Self.stay("c2", day: "2026-11-06", at: "2026-11-06T16:00:00Z", lat: 44.9),
                 Self.stay("c1", day: "2026-11-06", at: "2026-11-06T14:00:00Z", lat: 44.8)]
    #expect(MapFilter.trail(again).map(\.lat) == [44.8, 44.9])
  }

  @Test func timesWithOffsetsCompareAsMoments() {
    // 13:00 in Chicago is after 18:30 in London's winter: 19:00 against 18:30 UTC.
    let two = [Self.stay("c2", day: "2026-11-06", at: "2026-11-06T13:00:00-06:00", lat: 44.9),
               Self.stay("c1", day: "2026-11-06", at: "2026-11-06T18:30:00Z", lat: 51.5)]
    #expect(MapFilter.trail(two).map(\.lat) == [51.5, 44.9])
  }

  @Test func theNotesTrailRunsInTheOrderTheyWereWritten() {
    // A day's pins come in the order of their random ids, not their times.
    let day = [Self.pin("z", "2026-10-10", lat: 46.9, written: "2026-10-10T08:00:00-05:00"),
               Self.pin("a", "2026-10-10", lat: 46.7, written: "2026-10-10T19:00:00-05:00"),
               Self.pin("m", "2026-10-09", lat: 46.5, written: "2026-10-09T12:00:00Z"),
               Self.pin("q", "2026-10-10", lat: 46.8, written: nil)]
    #expect(MapFilter.trail(day).map(\.lat) == [46.5, 46.9, 46.7, 46.8])
  }

  @Test func theLineOverTheMapSaysWhatShows() {
    #expect(MapFilter().summary(stays: 34, notes: 1_204) == "34 check-ins and 1,204 notes.")
    #expect(MapFilter(year: 2026).summary(stays: 1, notes: 1) == "1 check-in and 1 note in 2026.")
    #expect(MapFilter(year: 2026).summary(stays: 0, notes: 0) == "No check-ins or notes in 2026.")
    #expect(MapFilter().summary(stays: 3, notes: nil) == "3 check-ins.")
    #expect(MapFilter(search: .words("first snow")).summary(stays: nil, notes: 2) == "2 notes with \u{201C}first snow\u{201D}.")
    #expect(MapFilter(year: 2025, search: .tag("lake")).summary(stays: nil, notes: 0) == "No notes tagged #lake in 2025.")
    #expect(MapFilter().summary(stays: nil, notes: nil) == "Turn on Check-ins or Notes to see them here.")
    #expect(MapFilter(search: .words("lake")).summary(stays: nil, notes: nil) == "A search finds notes: turn on Notes to see them.")
    #expect(MapFilter(search: .tag("lake")).summary(stays: nil, notes: nil) == "Turn on Check-ins or Notes to see them here.")
    #expect(MapFilter(search: .tag("road-trip")).summary(stays: 2, notes: 3, tagName: "Road Trip") ==
      "2 check-ins and 3 notes tagged Road Trip.")
    #expect(MapFilter(search: .tag("lake")).summary(stays: 0, notes: nil) == "No check-ins tagged #lake.")
  }

  @Test func pinsReadAsTheAPIWritesThem() throws {
    let json = """
    {"notes":12,"next":null,"pins":[{"date":"2026-10-10","id":"t-1","lat":46.78,"lon":-92.1,
     "place":"Duluth, Minnesota","exact":false,"tags":["lake"],"release":"4.5","version":"4.5.200",
     "text":"By the lake","parts":[{"t":"text","v":"By the lake"}],"written_at":"2026-10-10T12:00:00Z"},
     {"date":"2026-10-11","id":"t-2","lat":46.7,"lon":-92.1,"place":"Duluth, Minnesota","exact":true,
      "tags":[],"release":"4.5","version":"4.5.201","text":"","parts":[]}]}
    """
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    let list = try decoder.decode(MapPinList.self, from: Data(json.utf8))
    #expect(list.notes == 12 && list.next == nil)
    #expect(list.pins.map(\.key) == ["2026-10-10#t-1", "2026-10-11#t-2"])
    #expect(list.pins[0].writtenAt == "2026-10-10T12:00:00Z" && !list.pins[0].exact)
    #expect(list.pins[1].writtenAt == nil, "a server before 1.19.0 says no time")
  }
}
