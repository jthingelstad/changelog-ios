import Foundation

/// What the widgets show, written to the App Group by the app each time it
/// reads `/v1/me`, so a widget never calls the API or does the version
/// arithmetic: the days ahead come from the server's `days`. It never holds
/// a note's words.
public struct WidgetSnapshot: Codable, Sendable, Equatable {
  public var today: String
  public var version: String
  public var tz: String
  public var wroteToday: Bool
  public var days: [DayVersion]
  /// The next few Upcoming dates, soonest first, or nil for a token that
  /// can't read Upcoming. Their titles are the owner's own words: a widget
  /// shows them on the Home Screen only, never the Lock Screen.
  public var upcoming: [Soon]?

  public struct Soon: Codable, Sendable, Equatable {
    public var date: String
    /// A trip's last day.
    public var through: String?
    public var title: String
    public var kind: UpcomingKind

    public init(date: String, through: String? = nil, title: String, kind: UpcomingKind) {
      self.date = date
      self.through = through
      self.title = title
      self.kind = kind
    }
  }

  /// How many Upcoming dates are kept: a medium widget has room for two.
  public static let soonest = 3

  public init(me: Me, soon: [Soon]?) {
    today = me.today
    version = me.version
    tz = me.tz
    wroteToday = me.wroteToday
    days = me.days
    upcoming = soon
  }

  public init(me: Me, upcoming: [UpcomingEntry]?) {
    self.init(me: me, soon: upcoming.map(Self.soonest))
  }

  /// The soonest of a list of Upcoming dates, as the widgets keep them.
  public static func soonest(_ entries: [UpcomingEntry]) -> [Soon] {
    entries.filter { $0.status != "past" }
      .sorted { $0.next < $1.next }
      .prefix(soonest)
      .map { Soon(date: $0.next, through: $0.through, title: $0.fields.title, kind: $0.fields.kind) }
  }

  /// One day as a widget shows it, from its local midnight.
  public struct Day: Sendable, Equatable {
    public var date: String
    public var start: Date
    /// The next local midnight, when this day's version is over.
    public var end: Date
    public var version: String
    public var wrote: Bool
    /// Upcoming dates still ahead on this day (or a trip still on), soonest first.
    public var upcoming: [Soon]?

    public init(date: String, start: Date, end: Date, version: String, wrote: Bool, upcoming: [Soon]?) {
      self.date = date
      self.start = start
      self.end = end
      self.version = version
      self.wrote = wrote
      self.upcoming = upcoming
    }
  }

  /// The day `now` falls in and each day after it that the server listed,
  /// in the account's own time zone. Empty once the last listed day has
  /// passed: the widget then asks for the app to be opened.
  public func timeline(now: Date = .now) -> [Day] {
    guard let zone = TimeZone(identifier: tz) else { return [] }
    let parse = Date.ISO8601FormatStyle(timeZone: zone).year().month().day().dateSeparator(.dash)
    var listed = days
    if !listed.contains(where: { $0.date == today }) { listed.append(DayVersion(date: today, version: version)) }
    let calendar = Calendar.gregorian(zone)
    let all: [Day] = listed.compactMap { day in
      guard day.date >= today, let start = try? parse.parse(day.date),
            let end = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
      let ahead = upcoming?.filter { ($0.through ?? $0.date) >= day.date }
      return Day(date: day.date, start: start, end: end, version: day.version, wrote: day.date == today && wroteToday,
                 upcoming: ahead.map { Array($0.prefix(2)) })
    }.sorted { $0.start < $1.start }
    guard let current = all.lastIndex(where: { $0.start <= now }) else {
      // Before the first listed midnight (a clock behind the server's): from today.
      return all
    }
    // The last listed day is over: its version is no longer today's.
    guard now < all[current].end else { return [] }
    return Array(all[current...])
  }

  // MARK: Kept in the App Group

  public static let key = "widget.snapshot"

  public static func load(from defaults: UserDefaults? = AppGroup.defaults) -> WidgetSnapshot? {
    defaults?.data(forKey: key).flatMap { try? JSONDecoder().decode(WidgetSnapshot.self, from: $0) }
  }

  public func save(to defaults: UserDefaults? = AppGroup.defaults) {
    guard let data = try? JSONEncoder().encode(self) else { return }
    defaults?.set(data, forKey: Self.key)
  }

  /// A note filed from a shortcut or the share sheet, before the app next
  /// reads `/v1/me`: the day it filed to is written. A day after the
  /// snapshot's today means midnight has passed since: that day, with the
  /// server's version for it, is today now. True when that changed what the
  /// widgets show.
  @discardableResult
  public static func filed(on date: String, in defaults: UserDefaults? = AppGroup.defaults) -> Bool {
    guard var snapshot = load(from: defaults), date >= snapshot.today else { return false }
    if date > snapshot.today {
      // Past the listed days the widgets already ask for the app.
      guard let day = snapshot.days.first(where: { $0.date == date }) else { return false }
      snapshot.today = day.date
      snapshot.version = day.version
      snapshot.wroteToday = false
    }
    guard !snapshot.wroteToday else { return false }
    snapshot.wroteToday = true
    snapshot.save(to: defaults)
    return true
  }

  public static func clear(from defaults: UserDefaults? = AppGroup.defaults) {
    defaults?.removeObject(forKey: key)
  }
}

private extension Calendar {
  static func gregorian(_ zone: TimeZone) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    return calendar
  }
}
