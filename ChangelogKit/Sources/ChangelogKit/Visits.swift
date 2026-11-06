import Foundation

/// One event iOS delivered from its Visits service, as it came. The test of
/// whether Breakpoints can rest on Visits keeps these on the phone and sends
/// them nowhere.
public struct VisitEvent: Codable, Sendable, Equatable, Identifiable {
  public var id: UUID
  /// When the phone heard about it, which can be well after either time.
  public var heard: Date
  public var arrived: Date?
  public var left: Date?
  public var lat: Double
  public var lon: Double
  public var accuracyM: Double
  public var timeZone: String
  /// Whether the app was on the screen: "active" or "background".
  public var appState: String

  /// iOS writes an unknown arrival as the distant past and "still there" as
  /// the distant future; here both are nothing.
  public init(id: UUID = UUID(), heard: Date, arrival: Date, departure: Date, lat: Double, lon: Double,
              accuracyM: Double, timeZone: String, appState: String) {
    self.id = id
    self.heard = heard
    arrived = arrival <= .distantPast ? nil : arrival
    left = departure >= .distantFuture ? nil : departure
    self.lat = lat
    self.lon = lon
    self.accuracyM = accuracyM
    self.timeZone = timeZone
    self.appState = appState
  }
}

/// One stay: the events that share an arrival, since iOS can tell of a place
/// once on arriving and again on leaving.
public struct VisitStay: Sendable, Equatable, Identifiable {
  public var id: UUID
  public var arrived: Date?
  public var left: Date?
  public var firstHeard: Date
  public var lastHeard: Date
  public var lat: Double
  public var lon: Double
  public var accuracyM: Double
  public var events: Int

  public var minutes: Int? {
    guard let arrived, let left else { return nil }
    return Int(left.timeIntervalSince(arrived) / 60)
  }

  /// How long after arriving the phone first heard, if it heard while there.
  public var minutesToHearArrival: Int? {
    guard let arrived else { return nil }
    if let left, firstHeard >= left { return nil }
    return Int(firstHeard.timeIntervalSince(arrived) / 60)
  }

  public var minutesToHearLeaving: Int? {
    guard let left else { return nil }
    return Int(lastHeard.timeIntervalSince(left) / 60)
  }

  /// The events as stays, newest first. An event with no arrival stands alone.
  public static func from(_ events: [VisitEvent]) -> [VisitStay] {
    var stays: [VisitStay] = []
    var byArrival: [Int: Int] = [:]
    for event in events.sorted(by: { $0.heard < $1.heard }) {
      let key = event.arrived.map { Int($0.timeIntervalSince1970) }
      if let key, let at = byArrival[key] {
        stays[at].left = event.left ?? stays[at].left
        stays[at].lastHeard = event.heard
        stays[at].lat = event.lat
        stays[at].lon = event.lon
        stays[at].accuracyM = event.accuracyM
        stays[at].events += 1
      } else {
        if let key { byArrival[key] = stays.count }
        stays.append(VisitStay(id: event.id, arrived: event.arrived, left: event.left, firstHeard: event.heard,
                               lastHeard: event.heard, lat: event.lat, lon: event.lon, accuracyM: event.accuracyM,
                               events: 1))
      }
    }
    return stays.reversed()
  }
}

/// What the test is for: how short a stay iOS reports, how exactly and how
/// soon. Nothing where nothing has been measured yet.
public struct VisitSummary: Sendable, Equatable {
  public var stays: Int
  public var days: Int
  public var shortestMinutes: Int?
  public var medianMinutes: Int?
  public var medianAccuracyM: Int?
  public var medianMinutesToHearArrival: Int?
  public var medianMinutesToHearLeaving: Int?

  public init(_ stays: [VisitStay], calendar: Calendar = .current) {
    self.stays = stays.count
    days = Set(stays.map { calendar.startOfDay(for: $0.arrived ?? $0.firstHeard) }).count
    let minutes = stays.compactMap(\.minutes)
    shortestMinutes = minutes.min()
    medianMinutes = Self.median(minutes)
    medianAccuracyM = Self.median(stays.map { Int($0.accuracyM.rounded()) })
    medianMinutesToHearArrival = Self.median(stays.compactMap(\.minutesToHearArrival))
    medianMinutesToHearLeaving = Self.median(stays.compactMap(\.minutesToHearLeaving))
  }

  static func median(_ values: [Int]) -> Int? {
    guard !values.isEmpty else { return nil }
    return values.sorted()[values.count / 2]
  }
}

/// The events on disk, a line of JSON each, so an app ended between two
/// events loses neither. iOS can wake the app to write while the phone is
/// locked, so the file opens once the phone has been unlocked after starting,
/// and it stays out of backups, so the phone is the only place it is.
public struct VisitLog: Sendable {
  public let url: URL

  public init(url: URL) {
    self.url = url
  }

  public func append(_ event: VisitEvent) throws {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = .sortedKeys
    var line = try encoder.encode(event)
    line.append(0x0A)
    let files = FileManager.default
    if !files.fileExists(atPath: url.path) {
      try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try makeEmpty(files)
    }
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: line)
  }

  private func makeEmpty(_ files: FileManager) throws {
    #if os(iOS)
    try Data().write(to: url, options: .completeFileProtectionUntilFirstUserAuthentication)
    #else
    try Data().write(to: url)
    #endif
    var kept = url
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try kept.setResourceValues(values)
  }

  /// Oldest first. A line cut short by the app ending is left out.
  public func read() -> [VisitEvent] {
    guard let data = try? Data(contentsOf: url) else { return [] }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return data.split(separator: 0x0A).compactMap { try? decoder.decode(VisitEvent.self, from: Data($0)) }
  }

  public func clear() throws {
    guard FileManager.default.fileExists(atPath: url.path) else { return }
    try FileManager.default.removeItem(at: url)
  }
}
