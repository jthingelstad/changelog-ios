import Foundation

/// A note with a place of its own, as `GET /v1/map/pins` reads it: its day,
/// its spot, its tags and its opening words. Held in memory only, as every
/// note is. A place a note takes from its day makes no pin.
public struct NotePin: Codable, Sendable, Equatable, Hashable {
  public var date: String
  public var id: String
  public var lat: Double
  public var lon: Double
  /// The place on one line.
  public var place: String
  /// False when a city was chosen: it stands for the city, not a spot.
  public var exact: Bool
  public var tags: [String]
  public var release: String
  public var version: String
  /// The note's opening words.
  public var text: String
  /// When it was written (API 1.19.0): a day's pins come in no order of
  /// their own.
  public var writtenAt: String?

  public init(date: String, id: String, lat: Double, lon: Double, place: String, exact: Bool = true,
              tags: [String] = [], release: String = "", version: String = "", text: String = "",
              writtenAt: String? = nil) {
    self.date = date
    self.id = id
    self.lat = lat
    self.lon = lon
    self.place = place
    self.exact = exact
    self.tags = tags
    self.release = release
    self.version = version
    self.text = text
    self.writtenAt = writtenAt
  }

  /// Its day and id, which name a note everywhere.
  public var key: String { date + "#" + id }
}

/// A page of `GET /v1/map/pins`, oldest first.
public struct MapPinList: Codable, Sendable, Equatable {
  /// Every note in the archive, placed or not.
  public var notes: Int
  public var pins: [NotePin]
  public var next: String?
}

/// The notes at one spot, newest first: one dot on the map.
public struct NoteSpot: Identifiable, Sendable, Equatable {
  public var notes: [NotePin]

  public var id: String { "\(lat),\(lon)" }
  public var lat: Double { notes[0].lat }
  public var lon: Double { notes[0].lon }
  public var label: String { notes[0].place }
}

/// A spot on a trail.
public struct MapPoint: Sendable, Equatable, Hashable {
  public var lat: Double
  public var lon: Double

  public init(lat: Double, lon: Double) {
    self.lat = lat
    self.lon = lon
  }
}

/// What the map shows (Jamie, 2026-11-08): check-ins and notes, each on or
/// off; one year or every year; what a search finds, words or a #tag; and
/// trails, each kind joined in the order it happened.
public struct MapFilter: Sendable, Equatable, Hashable {
  public var checkIns: Bool
  public var notes: Bool
  /// A calendar year, by the day each was filed to, or nil for every year.
  public var year: Int?
  /// Words, or one #tag alone, as the Notes tab searches.
  public var search: NoteSearch?
  public var trails: Bool

  public init(checkIns: Bool = true, notes: Bool = true, year: Int? = nil, search: NoteSearch? = nil, trails: Bool = false) {
    self.checkIns = checkIns
    self.notes = notes
    self.year = year
    self.search = search
    self.trails = trails
  }

  /// Whether anything narrows what shows, beyond the two switches.
  public var narrows: Bool { year != nil || search != nil }

  /// The years with a check-in or a note on the map, newest first.
  public static func years(_ stays: [CheckIn], _ pins: [NotePin]) -> [Int] {
    Set(stays.compactMap { year(of: $0.day) } + pins.compactMap { year(of: $0.date) }).sorted(by: >)
  }

  static func year(of day: String) -> Int? { Int(day.prefix(4)) }

  private func inYear(_ day: String) -> Bool { year == nil || Self.year(of: day) == year }

  /// The check-ins it keeps. A search keeps notes alone, as on the web's
  /// Map: a check-in has no words or tags to find.
  public func stays(_ stays: [CheckIn]) -> [CheckIn] {
    guard checkIns, search == nil else { return [] }
    return stays.filter { inYear($0.day) }
  }

  /// The notes it keeps. A tag is read from the pins; words are found by
  /// Release Notes, and `found` holds the keys of the notes it found, nil
  /// until it answers.
  public func notes(_ pins: [NotePin], found: Set<String>?) -> [NotePin] {
    guard notes else { return [] }
    return pins.filter { pin in
      guard inYear(pin.date) else { return false }
      switch search {
      case nil: return true
      case .tag(let tag): return pin.tags.contains(tag)
      case .words: return found?.contains(pin.key) ?? false
      }
    }
  }

  /// The line over the map: what shows, of each kind that is on. `stays`
  /// and `notes` are nil for a kind that isn't on the map.
  public func summary(stays: Int?, notes: Int?) -> String {
    let found = switch search {
    case .words(let words): " with \u{201C}\(words)\u{201D}"
    case .tag(let tag): " tagged #\(tag)"
    case nil: ""
    }
    let when = year.map { " in \(String($0))" } ?? ""
    func count(_ n: Int, _ one: String, _ many: String) -> String { "\(n.formatted()) \(n == 1 ? one : many)" }
    switch (stays, notes) {
    case (nil, nil):
      return search == nil ? "Turn on Check-ins or Notes to see them here." : "A search finds notes: turn on Notes to see them."
    case (let stays?, nil):
      return stays == 0 ? "No check-ins\(when)." : "\(count(stays, "check-in", "check-ins"))\(when)."
    case (nil, let notes?):
      return notes == 0 ? "No notes\(found)\(when)." : "\(count(notes, "note", "notes"))\(found)\(when)."
    case (let stays?, let notes?):
      if stays == 0, notes == 0 { return "No check-ins or notes\(when)." }
      return "\(count(stays, "check-in", "check-ins")) and \(count(notes, "note", "notes"))\(when)."
    }
  }

  /// Notes at one spot share a dot, newest first.
  public static func spots(_ pins: [NotePin]) -> [NoteSpot] {
    var spots: [NoteSpot] = []
    var at: [MapPoint: Int] = [:]
    for pin in written(pins).reversed() {
      let point = MapPoint(lat: pin.lat, lon: pin.lon)
      if let i = at[point] {
        spots[i].notes.append(pin)
      } else {
        at[point] = spots.count
        spots.append(NoteSpot(notes: [pin]))
      }
    }
    return spots
  }

  /// The stays in the order they began, oldest first, joined; a stay at
  /// the spot just left adds nothing.
  public static func trail(_ stays: [CheckIn]) -> [MapPoint] {
    // `/v1` lists them newest first; `at` says when each began.
    let ordered = stays.enumerated().sorted { a, b in
      let x = moment(a.element.at), y = moment(b.element.at)
      return x != y ? x < y : a.offset > b.offset
    }
    return joined(ordered.map { MapPoint(lat: $0.element.lat, lon: $0.element.lon) })
  }

  /// The notes in the order they were written, oldest first, joined.
  public static func trail(_ pins: [NotePin]) -> [MapPoint] {
    joined(written(pins).map { MapPoint(lat: $0.lat, lon: $0.lon) })
  }

  /// Oldest first: by day, then by when each was written. A pin without a
  /// time comes after its day's others, in the order it came.
  static func written(_ pins: [NotePin]) -> [NotePin] {
    pins.enumerated()
      .map { (pin: $0.element, at: $0.element.writtenAt.map(moment) ?? .distantFuture, offset: $0.offset) }
      .sorted { a, b in
        if a.pin.date != b.pin.date { return a.pin.date < b.pin.date }
        return a.at != b.at ? a.at < b.at : a.offset < b.offset
      }
      .map(\.pin)
  }

  private static func joined(_ points: [MapPoint]) -> [MapPoint] {
    var line: [MapPoint] = []
    for point in points where point != line.last { line.append(point) }
    return line
  }

  private static func moment(_ stamp: String) -> Date { CheckInWords.date(stamp) ?? .distantPast }
}
