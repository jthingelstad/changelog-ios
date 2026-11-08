import Foundation

/// Upcoming dates as `/v1` names them (`GET /v1/upcoming`, `POST
/// /v1/upcoming/batch`, `DELETE /v1/upcoming/{id}`; the OpenAPI file's
/// `UpcomingFields`, `Upcoming`, `UpcomingBatch` and `UpcomingSaved`). A
/// date's title, day and destination are the owner's words: nothing here
/// logs them or puts them in an error.

public enum UpcomingKind: String, Codable, Sendable, CaseIterable, Identifiable {
  case birthday, anniversary, trip, event

  public var id: String { rawValue }

  /// Comes back every year, written `MM-DD`, with its first year if known.
  public var annual: Bool { self == .birthday || self == .anniversary }

  /// The server's own defaults (`packages/domain/upcoming.ts`): a week
  /// before, the day before and on the day; two weeks for a trip.
  public var defaultReminders: [Int] { self == .trip ? [14, 1, 0] : [7, 1, 0] }
}

/// A date as it is saved. A change sends every field again, as it should be;
/// a field left nil goes unsent, which the server reads as none.
public struct UpcomingFields: Codable, Sendable, Equatable {
  public var kind: UpcomingKind
  /// One line, up to 120 characters.
  public var title: String
  /// `MM-DD` for a birthday or anniversary, `YYYY-MM-DD` for a trip's first
  /// day or an event.
  public var date: String
  /// A birthday's or anniversary's first year, so the line can say which.
  public var year: Int?
  /// A trip's last day.
  public var endDate: String?
  /// A trip's destination (an event's place, if it has one), as text the
  /// city search knows: "Zürich", "Paris, Texas".
  public var place: String?
  /// Its tags, the whole list (API 1.21.0; call 5): read as `tags` and
  /// `tag_names`, or one `tag` from a server before, and sent by name.
  public var tags: [Tag]
  /// Days before to remind: up to six, at least one.
  public var reminders: [Int]
  /// Remind in the morning email, and so in apps.
  public var email: Bool

  public init(kind: UpcomingKind, title: String, date: String, year: Int? = nil, endDate: String? = nil,
              place: String? = nil, tags: [Tag] = [], reminders: [Int]? = nil, email: Bool = true) {
    self.kind = kind
    self.title = title
    self.date = date
    self.year = year
    self.endDate = endDate
    self.place = place
    self.tags = tags
    self.reminders = reminders ?? kind.defaultReminders
    self.email = email
  }

  enum CodingKeys: String, CodingKey { case kind, title, date, year, endDate, place, tag, tags, tagNames, reminders, email }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    kind = try c.decode(UpcomingKind.self, forKey: .kind)
    title = try c.decode(String.self, forKey: .title)
    date = try c.decode(String.self, forKey: .date)
    year = try c.decodeIfPresent(Int.self, forKey: .year)
    endDate = try c.decodeIfPresent(String.self, forKey: .endDate)
    place = try c.decodeIfPresent(String.self, forKey: .place)
    if let keys = try c.decodeIfPresent([String].self, forKey: .tags) {
      tags = Hashtags.named(keys, try c.decodeIfPresent([String].self, forKey: .tagNames))
    } else if let one = try c.decodeIfPresent(String.self, forKey: .tag), !one.isEmpty {
      tags = [Tag(key: one, name: one)]
    } else {
      tags = []
    }
    reminders = try c.decodeIfPresent([Int].self, forKey: .reminders) ?? kind.defaultReminders
    email = try c.decodeIfPresent(Bool.self, forKey: .email) ?? true
  }

  /// The tags go by name, the whole list; never the deprecated `tag`.
  public func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(kind, forKey: .kind)
    try c.encode(title, forKey: .title)
    try c.encode(date, forKey: .date)
    try c.encodeIfPresent(year, forKey: .year)
    try c.encodeIfPresent(endDate, forKey: .endDate)
    try c.encodeIfPresent(place, forKey: .place)
    try c.encode(tags.map(\.name), forKey: .tags)
    try c.encode(reminders, forKey: .reminders)
    try c.encode(email, forKey: .email)
  }
}

/// One saved date, with the server's own line ("Mom turns 7.0.0. A major
/// release.") and its next occurrence.
public struct UpcomingEntry: Codable, Sendable, Equatable, Identifiable {
  public var id: String
  /// Send it back to change or remove the date. A whole number on `/v1`.
  public var revision: Int
  /// Its next date, or today while a trip is on.
  public var next: String
  /// A trip's last day this time.
  public var through: String?
  /// upcoming, today, ongoing or past.
  public var status: String
  public var line: String
  public var fields: UpcomingFields

  public init(id: String, revision: Int, next: String, through: String? = nil, status: String = "upcoming",
              line: String, fields: UpcomingFields) {
    self.id = id
    self.revision = revision
    self.next = next
    self.through = through
    self.status = status
    self.line = line
    self.fields = fields
  }

  enum CodingKeys: String, CodingKey { case id, revision, next, through, status, line }

  /// The answer has the fields and the rest side by side in one object.
  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(String.self, forKey: .id)
    revision = try c.decode(Int.self, forKey: .revision)
    next = try c.decode(String.self, forKey: .next)
    through = try c.decodeIfPresent(String.self, forKey: .through)
    status = try c.decode(String.self, forKey: .status)
    line = try c.decode(String.self, forKey: .line)
    fields = try UpcomingFields(from: decoder)
  }

  public func encode(to encoder: any Encoder) throws {
    try fields.encode(to: encoder)
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(id, forKey: .id)
    try c.encode(revision, forKey: .revision)
    try c.encode(next, forKey: .next)
    try c.encodeIfPresent(through, forKey: .through)
    try c.encode(status, forKey: .status)
    try c.encode(line, forKey: .line)
  }
}

/// How far off a date is, in whole calendar days. Days as the API writes them,
/// counted in a calendar with no clock changes, so one never comes out short.
public enum UpcomingCountdown {
  private static let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
    return calendar
  }()

  private static func date(_ day: String) -> Date? {
    guard let (y, m, d) = UpcomingDraft.parse(day) else { return nil }
    return calendar.date(from: DateComponents(year: y, month: m, day: d))
  }

  public static func days(from today: String, to day: String) -> Int? {
    guard let start = date(today), let end = date(day) else { return nil }
    return calendar.dateComponents([.day], from: start, to: end).day
  }

  /// "Tomorrow", "In 7 days", and from two weeks on "3 weeks 2 days". Nothing
  /// for today or a day gone: the row says those itself.
  public static func words(to day: String, today: String) -> String? {
    guard let days = days(from: today, to: day), days > 0 else { return nil }
    if days == 1 { return "Tomorrow" }
    if days < 14 { return "In \(days) days" }
    let (weeks, left) = days.quotientAndRemainder(dividingBy: 7)
    let inWeeks = "\(weeks) weeks"
    return switch left {
    case 0: inWeeks
    case 1: inWeeks + " 1 day"
    default: inWeeks + " \(left) days"
    }
  }
}

/// One month of the dates ahead, under its own heading. A trip already on
/// has today as its next date, so it sits in this month.
public struct UpcomingMonth: Sendable, Equatable, Identifiable {
  /// `YYYY-MM`.
  public var id: String
  /// "December", and "January 2027" when it isn't this year's. Nothing for a
  /// date the app can't read, which still shows, at the end.
  public var title: String?
  public var entries: [UpcomingEntry]
}

extension UpcomingList {
  /// The entries in the server's order, by the month of their next date.
  public func months(locale: Locale = .current) -> [UpcomingMonth] {
    var calendar = Calendar(identifier: .gregorian)
    calendar.locale = locale
    let names = calendar.standaloneMonthSymbols
    var months: [UpcomingMonth] = []
    var unread: [UpcomingEntry] = []
    for entry in entries {
      guard let (year, month, _) = UpcomingDraft.parse(entry.next) else {
        unread.append(entry)
        continue
      }
      let id = String(entry.next.prefix(7))
      if let at = months.firstIndex(where: { $0.id == id }) {
        months[at].entries.append(entry)
      } else {
        let name = names[month - 1]
        let title = entry.next.prefix(4) == today.prefix(4) ? name : "\(name) \(year)"
        months.append(UpcomingMonth(id: id, title: title, entries: [entry]))
      }
    }
    if !unread.isEmpty { months.append(UpcomingMonth(id: "unread", title: nil, entries: unread)) }
    return months
  }
}

/// `GET /v1/upcoming`: every date ahead, soonest first. A one-time date
/// already over is left out and only counted, since it still takes one of
/// the account's `maxEntries`.
public struct UpcomingList: Decodable, Sendable, Equatable {
  public var today: String
  public var entries: [UpcomingEntry]
  public var pastLeftOut: Int
  public var maxEntries: Int
  /// Dates of a kind this version doesn't know, from a later server: left
  /// out rather than failing the whole list.
  public var unreadable: Int

  public init(today: String, entries: [UpcomingEntry], pastLeftOut: Int = 0, maxEntries: Int = 200, unreadable: Int = 0) {
    self.today = today
    self.entries = entries
    self.pastLeftOut = pastLeftOut
    self.maxEntries = maxEntries
    self.unreadable = unreadable
  }

  enum CodingKeys: String, CodingKey { case today, entries, pastLeftOut, maxEntries }

  private struct Lossy: Decodable {
    var entry: UpcomingEntry?
    init(from decoder: any Decoder) throws { entry = try? UpcomingEntry(from: decoder) }
  }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    today = try c.decode(String.self, forKey: .today)
    let rows = try c.decode([Lossy].self, forKey: .entries)
    entries = rows.compactMap(\.entry)
    unreadable = rows.count - entries.count
    pastLeftOut = try c.decodeIfPresent(Int.self, forKey: .pastLeftOut) ?? 0
    maxEntries = try c.decodeIfPresent(Int.self, forKey: .maxEntries) ?? 200
  }
}

/// A change: every field again, from the revision read.
public struct UpcomingChange: Encodable, Sendable, Equatable {
  public var id: String
  public var revision: Int
  public var fields: UpcomingFields

  public init(id: String, revision: Int, fields: UpcomingFields) {
    self.id = id
    self.revision = revision
    self.fields = fields
  }

  enum CodingKeys: String, CodingKey { case id, revision }

  public func encode(to encoder: any Encoder) throws {
    try fields.encode(to: encoder)
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(id, forKey: .id)
    try c.encode(revision, forKey: .revision)
  }
}

public struct UpcomingRemoval: Codable, Sendable, Equatable {
  public var id: String
  public var revision: Int

  public init(id: String, revision: Int) {
    self.id = id
    self.revision = revision
  }
}

/// `POST /v1/upcoming/batch`: all or nothing, at most 50 entries. With
/// `dryRun` it checks everything and finds each destination's city, and
/// saves nothing (a read, not one of the day's 50 saves).
public struct UpcomingBatch: Encodable, Sendable, Equatable {
  public var add: [UpcomingFields]
  public var change: [UpcomingChange]
  public var remove: [UpcomingRemoval]
  public var dryRun: Bool

  public init(add: [UpcomingFields] = [], change: [UpcomingChange] = [], remove: [UpcomingRemoval] = [], dryRun: Bool = false) {
    self.add = add
    self.change = change
    self.remove = remove
    self.dryRun = dryRun
  }

  public static func adding(_ fields: UpcomingFields, dryRun: Bool = false) -> UpcomingBatch {
    UpcomingBatch(add: [fields], dryRun: dryRun)
  }

  public static func changing(_ entry: UpcomingEntry, to fields: UpcomingFields, dryRun: Bool = false) -> UpcomingBatch {
    UpcomingBatch(change: [UpcomingChange(id: entry.id, revision: entry.revision, fields: fields)], dryRun: dryRun)
  }

  public static func removing(_ entry: UpcomingEntry) -> UpcomingBatch {
    UpcomingBatch(remove: [UpcomingRemoval(id: entry.id, revision: entry.revision)])
  }

  enum CodingKeys: String, CodingKey { case add, change, remove, dryRun }

  /// Only the lists that hold something, and `dry_run` only when it is one.
  public func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    if !add.isEmpty { try c.encode(add, forKey: .add) }
    if !change.isEmpty { try c.encode(change, forKey: .change) }
    if !remove.isEmpty { try c.encode(remove, forKey: .remove) }
    if dryRun { try c.encode(true, forKey: .dryRun) }
  }
}

/// What a batch saved, or with a dry run would have: the dates as they now
/// read, with the cities found.
public struct UpcomingSaved: Decodable, Sendable, Equatable {
  public var dryRun: Bool
  /// In the order they were sent, with their new ids.
  public var added: [UpcomingEntry]
  public var changed: [UpcomingEntry]
  /// The ids removed.
  public var removed: [String]
  /// Badges this save earned, only while Show badges is on.
  public var unlocked: [Unlocked]?

  /// The one date a single add or change saved.
  public var saved: UpcomingEntry? { added.first ?? changed.first }
}

public extension APIError {
  /// The server's sentence for a refused date, without the `(add[0])` it
  /// names the entry by: the app sends one at a time. It never holds the
  /// date's own words.
  var upcomingSentence: String {
    message.replacingOccurrences(of: #" \((?:add|change|remove)\[\d+\]\)"#, with: "", options: .regularExpression)
  }
  /// For a call made with no one signed in: the same as a token that
  /// stopped working, so the app asks for one.
  static let notSignedIn = APIError(status: 401, code: "token_missing", message: "Sign in again to keep your Upcoming dates.")
}
