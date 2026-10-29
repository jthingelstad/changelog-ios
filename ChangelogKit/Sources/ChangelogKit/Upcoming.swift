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
  /// One word, like `family`, without the `#`.
  public var tag: String?
  /// Days before to remind: up to six, at least one.
  public var reminders: [Int]
  /// Remind in the morning email, and so in apps.
  public var email: Bool

  public init(kind: UpcomingKind, title: String, date: String, year: Int? = nil, endDate: String? = nil,
              place: String? = nil, tag: String? = nil, reminders: [Int]? = nil, email: Bool = true) {
    self.kind = kind
    self.title = title
    self.date = date
    self.year = year
    self.endDate = endDate
    self.place = place
    self.tag = tag
    self.reminders = reminders ?? kind.defaultReminders
    self.email = email
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
