import Foundation
import UniformTypeIdentifiers

/// The shapes of Release Notes' `/v1` API, as `docs/API.md` in
/// jthingelstad/yvn-release-notes defines them. Fields arrive in snake_case
/// and decode through `APIClient`'s decoder. Every field a later API version
/// may add is ignored until a type here names it, since `/v1` only gains.

/// `GET /v1/me`: what the app needs to show today's version and to schedule
/// anything offline. Versions come from the server, never computed here.
public struct Me: Codable, Sendable, Equatable {
  public var today: String
  public var version: String
  public var tz: String
  public var sendTime: String
  public var wroteToday: Bool
  public var streak: Int
  public var pausedUntil: String?
  public var status: String
  public var showBadges: Bool
  public var days: [DayVersion]
  public var token: TokenInfo
  public var apiVersion: String
  /// Whose account the token opens (API 1.4.0): `acct_` and 32 hex
  /// characters, the same for every token of the account and never
  /// changing. A queued note is stamped with it (`OutboxItem.account`). Nil
  /// from a server before 1.4.0.
  public var account: String? = nil
  /// Whether the account gets what Supporting Members of the Weekly Thing
  /// get (API 1.12.0): the app's other icons. Nil from a server before
  /// 1.12.0, which reads as no.
  public var supportingMember: Bool? = nil
  /// The weeks and days lived today (API 1.13.0), as Release Notes' Today
  /// page and morning email write them. Nil from a server before 1.13.0.
  public var lived: Lived? = nil

  /// The version for a local day the server listed in `days`, so a widget or
  /// an offline header can show tomorrow's number without the arithmetic.
  public func version(on date: String) -> String? {
    date == today ? version : days.first { $0.date == date }?.version
  }
}

public struct DayVersion: Codable, Sendable, Equatable {
  public var date: String
  public var version: String
  /// That day's weeks and days lived (API 1.13.0).
  public var lived: Lived? = nil
}

/// Weeks and days lived, both from 1 (API 1.13.0): a nod to Four Thousand
/// Weeks, which Release Notes' Today page and morning email set under the
/// version. The day grows by one a day; the week follows from it.
public struct Lived: Codable, Sendable, Equatable {
  public var week: Int
  public var day: Int

  public init(week: Int, day: Int) {
    self.week = week
    self.day = day
  }

  /// "Week 2,826 — Day 19,779", as the web and the email write it
  /// (`livedText` in Release Notes): US digit grouping on any phone.
  public var text: String { "\(weekText) \u{2014} \(dayText)" }
  /// "Week 2,826", for where the line has to break.
  public var weekText: String { "Week \(week.formatted(Self.grouped))" }
  /// "Day 19,779".
  public var dayText: String { "Day \(day.formatted(Self.grouped))" }

  private static let grouped = IntegerFormatStyle<Int>.number.locale(Locale(identifier: "en_US"))
}

public struct TokenInfo: Codable, Sendable, Equatable {
  public var name: String
  public var scopes: [String]
  public var expiresAt: String?
  /// The token's own record id (API 1.4.0), 32 hex characters, which each
  /// activity row it writes carries as `token_id`. It grants nothing: never
  /// the token or its hash. Nil from a server before 1.4.0.
  public var id: String? = nil

  /// Whether it reads every note, wherever made (`notes:all`, or `notes:read`
  /// beside `notes:write`, API 1.15.0), so the Notes tab opens.
  public var readsAll: Bool { scopes.contains("notes:all") || scopes.contains("notes:read") }
  /// Whether it changes and deletes every note. `notes:read` alone reads
  /// them and changes only the notes this token wrote.
  public var changesAll: Bool { scopes.contains("notes:all") }
}

/// `POST /v1/notes`. `writtenAt` is the moment the words were typed, so a
/// note queued offline files to the day it was written. A note with files
/// needs no words: `text` nil leaves it out.
public struct NoteRequest: Codable, Sendable, Equatable {
  public var text: String?
  public var date: String?
  public var writtenAt: String?
  public var uploads: [UploadRef]?
  public var place: DevicePlace?
  /// Tags by name (API 1.21.0): "Road Trip", "🚗 Lake". The hashtags in
  /// `text` are tags too, after these.
  public var tags: [String]?

  public init(text: String?, date: String? = nil, writtenAt: String? = nil, uploads: [UploadRef]? = nil, place: DevicePlace? = nil,
              tags: [String]? = nil) {
    self.text = text
    self.date = date
    self.writtenAt = writtenAt
    self.uploads = uploads
    self.place = place
    self.tags = tags?.isEmpty == true ? nil : tags
  }
}

/// A note this token wrote, as the API names it.
public struct NoteRef: Codable, Sendable, Equatable, Hashable {
  public var id: String
  public var date: String
  public var version: String
  /// Opaque: send it back to edit, never compare or count it.
  public var revision: String
  public var token: String?
  /// How many files the note has.
  public var files: Int?
}

public struct Unlocked: Codable, Sendable, Equatable {
  public var key: String
  public var name: String
}

public struct NoteReceipt: Codable, Sendable, Equatable {
  public var note: NoteRef
  public var unlocked: [Unlocked]?
}

/// `GET /v1/notes/{date}/{id}`, or one of a list: a note this token wrote, or
/// any note for a token that reads them all. Everything past `files` is from
/// API 1.14.0 or later, and nil from a server before it. Held in memory only:
/// never on disk, in the App Group, a widget, a notification or what Siri says.
public struct NoteDetail: Codable, Sendable, Hashable, Identifiable {
  public var id: String
  public var date: String
  public var text: String
  public var revision: String
  public var writtenAt: String?
  public var files: Int?
  public var version: String? = nil
  public var media: [NoteFileEntry]? = nil
  public var token: String? = nil
  /// Where it was made: `email`, `web`, `api` and the rest.
  public var source: String? = nil
  /// Whether this token wrote it.
  public var mine: Bool? = nil
  /// Its tags' keys, and their names beside them (API 1.21.0).
  public var tags: [String]? = nil
  public var tagNames: [String]? = nil
  /// `rich` when `text` holds rich-text marks; nil for plain words.
  public var markup: String? = nil
  /// Its words cut up to show them. A rich note's carry the marks as typed.
  public var parts: [NotePart]? = nil
  /// Its own place, never one it takes from its day.
  public var place: NotePlaceRead? = nil
  public var noPlace: Bool? = nil
  public var editedAt: String? = nil
  /// The zone it was written in.
  public var tz: String? = nil
  /// Written after the day it is filed on had ended.
  public var late: Bool? = nil
  /// `assistant` when an agent wrote it, in its own voice.
  public var author: String? = nil
  public var client: String? = nil
  public var from: String? = nil
  /// How many files its email carried that Release Notes did not keep.
  public var attachments: Int? = nil

  public var isRich: Bool { markup == "rich" }

  /// Its tags by name: from its tags field and its #words, as kept. A server
  /// before 1.21.0 names them by their keys, or by the words' #words.
  public var tagList: [Tag] {
    guard let tags else { return Hashtags.textTags(text) }
    let typed = (tagNames?.count ?? 0) < tags.count ? Hashtags.textTags(text) : []
    let names = tagNames ?? []
    return Hashtags.merge(tags.enumerated().map { i, key in
      let name = i < names.count && !names[i].isEmpty ? names[i] : typed.first { $0.key == key }?.name ?? key
      return Tag(key: key, name: name)
    })
  }

  /// The tags its words don't show as #words: the ones its tags field gave
  /// it, said under it.
  public var fieldTags: [Tag] { Hashtags.fieldOnly(text, tags: tagList) }

  /// A recording's words are still being written, so a read soon may bring
  /// its transcript.
  public var wordsComing: Bool {
    (media ?? []).contains { $0.kind == "audio" && $0.writing == true && $0.transcript == nil }
  }

  /// The words without their marks, for a line in a list.
  public var plainWords: String {
    isRich ? Rich.words(Rich.blocks(parts ?? [.text(text)])) : text
  }

  /// Where it came from, in the words the web's note line uses.
  public var sourceName: String {
    if author == "assistant" { return "added by \(client ?? "an agent")" }
    switch source {
    case "web": return "on the web"
    case "api": return token.map { "via \($0)" } ?? "through the API"
    case "import": return "from \(from ?? "an import")"
    default: return "by email"
    }
  }

  /// The email it came in goes with it when it is deleted.
  public var hasEmail: Bool { source == nil || source == "email" }
}

/// One stretch of a note's words: words, a link by name, or a hashtag. A kind
/// a later API version adds reads as nothing rather than failing the note.
public enum NotePart: Codable, Sendable, Equatable {
  case text(String)
  case link(url: String, label: String, site: String?)
  case tag(tag: String, text: String)
  case other

  private enum Keys: String, CodingKey { case url, label, site, tag, text }

  public init(from decoder: any Decoder) throws {
    if let words = try? decoder.singleValueContainer().decode(String.self) {
      self = .text(words)
      return
    }
    guard let keys = try? decoder.container(keyedBy: Keys.self) else {
      self = .other
      return
    }
    if let url = try? keys.decode(String.self, forKey: .url), let label = try? keys.decode(String.self, forKey: .label) {
      self = .link(url: url, label: label, site: try? keys.decode(String.self, forKey: .site))
    } else if let tag = try? keys.decode(String.self, forKey: .tag), let text = try? keys.decode(String.self, forKey: .text) {
      self = .tag(tag: tag, text: text)
    } else {
      self = .other
    }
  }

  public func encode(to encoder: any Encoder) throws {
    switch self {
    case .text(let words):
      var one = encoder.singleValueContainer()
      try one.encode(words)
    case .link(let url, let label, let site):
      var keys = encoder.container(keyedBy: Keys.self)
      try keys.encode(url, forKey: .url)
      try keys.encode(label, forKey: .label)
      try keys.encodeIfPresent(site, forKey: .site)
    case .tag(let tag, let text):
      var keys = encoder.container(keyedBy: Keys.self)
      try keys.encode(tag, forKey: .tag)
      try keys.encode(text, forKey: .text)
    case .other:
      var one = encoder.singleValueContainer()
      try one.encode("")
    }
  }
}

/// One of a note's files (API 1.9.0), its number kept even when others go.
public struct NoteFileEntry: Codable, Sendable, Equatable, Identifiable {
  public var n: Int
  /// `image`, `audio` or `file`.
  public var kind: String
  public var type: String
  public var name: String?
  public var size: Int
  public var thumb: Thumb?
  /// A recording's words, once the owner's opt-in transcript is kept.
  public var transcript: String? = nil
  /// A photo's description, once the owner's opt-in one is kept.
  public var description: String? = nil
  /// A transcript of this recording is still to come.
  public var writing: Bool? = nil
  /// With `include=urls`: the file's address, good for ten minutes.
  public var url: String? = nil

  public var id: Int { n }

  public struct Thumb: Codable, Sendable, Equatable {
    public var width: Int? = nil
    public var height: Int? = nil
    public var url: String? = nil
  }

  /// A name for the file on this phone, for as long as it is previewed: its
  /// own, with no folders in it, or one made from what it is and its type.
  public var previewName: String {
    let own = (name ?? "").replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
    let kept = own.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
    let suffix = UTType(mimeType: type)?.preferredFilenameExtension
    if kept.isEmpty {
      let plain = kind == "audio" ? "Voice memo" : kind == "image" ? "Photo" : "file"
      return suffix.map { "\(plain).\($0)" } ?? plain
    }
    return (kept as NSString).pathExtension.isEmpty ? (suffix.map { "\(kept).\($0)" } ?? kept) : kept
  }
}

/// `GET /v1/notes/{date}/{id}/media/{n}`: an address, fetched with no token.
public struct FileAddress: Codable, Sendable, Equatable {
  public var url: String
  public var type: String
  public var expiresIn: Int? = nil
}

/// `GET /v1/notes?from=&to=`: oldest first, with the `after` for the next page.
public struct NoteList: Codable, Sendable, Equatable {
  public var items: [NoteDetail]
  public var next: String?
}

/// What a day says of where it was, when a note has no place of its own.
public struct DayAround: Codable, Sendable, Equatable {
  public var label: String
  public var from: String
}

/// A day's weather. `line` is as the web says it; wherever it shows, the
/// answer's `weatherCredit` shows too.
public struct DayWeather: Codable, Sendable, Equatable {
  public var line: String
}

/// `GET /v1/days`: a day in the timeline, newest first.
public struct DaySummary: Codable, Sendable, Equatable, Identifiable {
  public var date: String
  public var version: String
  public var place: NotePlaceRead?
  public var around: DayAround?
  public var weather: DayWeather?
  public var notesTotal: Int
  public var files: Int
  public var emailed: Bool
  public var paused: Bool

  public var id: String { date }
}

/// `GET /v1/days`, with the `before` for the next page.
public struct DayList: Codable, Sendable, Equatable {
  public var today: String
  public var tz: String
  public var days: [DaySummary]
  public var next: String?
  public var weatherCredit: String?
}

/// `GET /v1/days/{date}`: its first notes, with the `after` for `/v1/notes`.
public struct DayDetail: Codable, Sendable, Equatable {
  public var date: String
  public var version: String
  public var place: NotePlaceRead?
  public var around: DayAround?
  public var weather: DayWeather?
  public var today: Bool
  public var tz: String
  public var paused: Bool
  public var notesTotal: Int
  public var notes: [NoteDetail]
  public var next: String?
  public var weatherCredit: String?
}

/// `GET /v1/search` (API 1.15.0): the notes that have every word, or a tag's
/// notes, newest first, with the `after` for the next page.
public struct SearchResults: Codable, Sendable, Equatable {
  /// What was looked for, as the server read it.
  public var terms: [String]
  public var tag: String?
  /// Every note found, across every page.
  public var total: Int
  public var items: [NoteDetail]
  public var next: String?
}

/// `GET /v1/on-this-day` (API 1.15.0): the same day of each earlier release,
/// newest first, as the morning email's On this day. Only days with notes.
public struct OnThisDay: Codable, Sendable, Equatable {
  public var date: String
  public var version: String
  public var days: [PastDay]
  /// The `before` for the next page of years.
  public var next: String?

  public struct PastDay: Codable, Sendable, Equatable, Identifiable {
    public var date: String
    public var version: String
    public var notesTotal: Int
    /// Its first notes; the day's own page has the rest.
    public var notes: [NoteDetail]

    public var id: String { date }

    /// The notes this answer left for the day's own page.
    public var more: Int { max(0, notesTotal - notes.count) }

    /// How many years before `day` (both yyyy-mm-dd) this one is.
    public func years(before day: String) -> Int {
      max(1, (Int(day.prefix(4)) ?? 0) - (Int(date.prefix(4)) ?? 0))
    }
  }
}

/// What the Notes tab's search box asks for: one `#tag` alone is that tag's
/// page, as the web's tag links are; anything else is words, which the server
/// reads as the web's search does (every word, "quoted phrases").
public enum NoteSearch: Sendable, Equatable, Hashable {
  case words(String)
  case tag(String)

  /// Nil for a box with nothing in it.
  public init?(_ typed: String) {
    let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return nil }
    let spans = Hashtags.spans(text)
    if spans.count == 1, let only = spans.first, only.start == 0, only.end == text.unicodeScalars.count {
      self = .tag(only.tag)
    } else {
      self = .words(text)
    }
  }

  /// As the owner sees it asked: the words, or the tag with its #.
  public var shown: String {
    switch self {
    case .words(let words): words
    case .tag(let tag): "#\(tag)"
    }
  }
}

/// A place as the web shows it: `label` is the whole of it on one line.
public struct NotePlaceRead: Codable, Sendable, Equatable {
  public var label: String
}

/// `GET /v1/tags`: the pinned list, then the most used in the last 30 days.
/// Since API 1.21.0 the pins are kept by name, and each tag has its name.
public struct Tags: Codable, Sendable, Equatable {
  public var pinned: [String]
  public var pinnedNames: [String]? = nil
  public var recent: [RecentTag]
  public var windowDays: Int?

  public init(pinned: [String], pinnedNames: [String]? = nil, recent: [RecentTag], windowDays: Int? = nil) {
    self.pinned = pinned
    self.pinnedNames = pinnedNames
    self.recent = recent
    self.windowDays = windowDays
  }

  /// The pins by name.
  public var pinnedTags: [Tag] { Hashtags.named(pinned, pinnedNames) }
}

public struct RecentTag: Codable, Sendable, Equatable {
  public var tag: String
  public var name: String? = nil
  public var count: Int
  public var lastUsed: String?

  public init(tag: String, name: String? = nil, count: Int, lastUsed: String? = nil) {
    self.tag = tag
    self.name = name
    self.count = count
    self.lastUsed = lastUsed
  }
}

/// `GET /v1/tags/all`: every tag, most used first, by name, with what carries
/// it. `upcoming` is nil without the `upcoming` scope, and `checkIns`
/// without `activity` (API 1.21.0).
public struct TagTotals: Codable, Sendable, Equatable {
  public var tags: [TagTotal]
}

public struct TagTotal: Codable, Sendable, Equatable, Identifiable, Hashable {
  public var tag: String
  public var name: String?
  public var notes: Int
  public var days: Int
  public var first: String?
  public var last: String?
  public var upcoming: Int?
  public var checkIns: Int?

  public init(tag: String, name: String? = nil, notes: Int, days: Int, first: String? = nil, last: String? = nil,
              upcoming: Int? = nil, checkIns: Int? = nil) {
    self.tag = tag
    self.name = name
    self.notes = notes
    self.days = days
    self.first = first
    self.last = last
    self.upcoming = upcoming
    self.checkIns = checkIns
  }

  public var id: String { tag }
  public var named: Tag { Tag(key: tag, name: name ?? tag) }

  /// "3 days, 1 date, 2 check-ins": what carries it, each only when it does,
  /// as the web's tags list says it.
  public var carried: String {
    var out: [String] = []
    if days > 0 { out.append(days == 1 ? "1 day" : "\(days) days") }
    if let upcoming, upcoming > 0 { out.append(upcoming == 1 ? "1 date" : "\(upcoming) dates") }
    if let checkIns, checkIns > 0 { out.append(checkIns == 1 ? "1 check-in" : "\(checkIns) check-ins") }
    return out.joined(separator: ", ")
  }
}

/// `GET /v1/activity`: newest first, trimmed of words on the server.
public struct ActivityPage: Codable, Sendable, Equatable {
  public var items: [ActivityItem]
  public var next: String?
}

/// One row of the activity log. Kinds are open-ended ("note.added",
/// "mail", "badge.earned", ...), so only the fields the app shows are named.
public struct ActivityItem: Codable, Sendable, Equatable, Identifiable {
  public var id: String
  public var at: String
  public var kind: String
  public var via: String?
  public var client: String?
  public var token: String?
  public var day: String?
  public var version: String?
  public var note: String?
  public var files: Int?
  public var outcome: String?
  public var name: String?
  public var title: String?
  /// The `token.id` of the token that wrote the row (API 1.4.0). A row
  /// written before then has none (the field is left out, never null).
  public var tokenId: String? = nil
  /// A check-in's row: the stay's id, its name, its times, where those times
  /// read, whether a tap or a visit. Never its spot.
  public var checkin: String? = nil
  public var label: String? = nil
  public var arrived: String? = nil
  public var left: String? = nil
  public var timeZone: String? = nil
  /// A check-in's row: `visit` or `tap`.
  public var source: String? = nil
  /// A `checkin.deleted` row: every check-in went, and how many.
  public var all: Bool? = nil
  public var count: Int? = nil
  /// A `checkin.place` row: `added`, `spot`, `renamed` or `forgotten`.
  public var change: String? = nil
  /// A `checkin.place`, `checkin.ignored` or `checkin.unignored` row, or a
  /// `checkin.deleted` of the check-ins at one place (API 1.20.0): the
  /// remembered place's id, never its name.
  public var place: String? = nil

  public var family: String { String(kind.split(separator: ".").first ?? Substring(kind)) }

  /// Whether `token` wrote this row: by id when the row and `/v1/me` both
  /// have one, so a later token given the same name is never taken for this
  /// one; by the token's name only for a row from before API 1.4.0, which
  /// has no `token_id`.
  public func isBy(_ token: TokenInfo) -> Bool {
    guard via == "token" else { return false }
    if let tokenId { return tokenId == token.id }
    return self.token == token.name
  }

  /// Through what it came, in the owner's words.
  public var channel: String? {
    switch via {
    case "token": token.map { "via \($0)" } ?? "via a token"
    case "assistant": client.map { "by \($0)" } ?? "by an agent"
    case "email": "by email"
    case "web": "on the web"
    case "import": "by import"
    default: nil
    }
  }

  /// Under the headline: how it came and its day. A reminder went out in the
  /// daily email; it didn't come in by one.
  public var detail: String? {
    if kind == "checkin" {
      let parts = [stayLine, channel].compactMap { $0 }
      return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
    let parts = [kind == "reminder" ? "in the daily email" : channel, day].compactMap { $0 }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }

  /// A check-in's times, in the zone it happened in.
  public var stayLine: String? {
    CheckInWords.stay(arrived: arrived, left: left, source: source, timeZone: timeZone.flatMap(TimeZone.init(identifier:)) ?? .current)
  }

  /// A check-in row's headline, in the web's words; nil for another family. A
  /// kind or a change this build doesn't know reads as a change, never as
  /// something else.
  public var checkInHeadline: String? {
    guard family == "checkin" else { return nil }
    switch kind {
    case "checkin": return "Checked in at \(CheckInWords.stopName(label))"
    case "checkin.named": return "Named a check-in"
    case "checkin.deleted":
      if all == true { return count.map { "Deleted all your check-ins, \($0)" } ?? "Deleted all your check-ins" }
      return place == nil ? "Deleted a check-in" : "Deleted the check-ins at a remembered place"
    case "checkin.ignored": return "Ignored a remembered place"
    case "checkin.unignored": return "Stopped ignoring a remembered place"
    case "checkin.place":
      switch change {
      case "added": return "Remembered a place"
      case "spot": return "Added a spot to a remembered place"
      case "renamed": return "Renamed a remembered place"
      case "forgotten": return "Forgot a remembered place"
      default: return "Changed a remembered place"
      }
    default: return "Changed your check-ins"
    }
  }

  /// The line the web has under a check-in row's headline: what ignoring a
  /// place does, or how many check-ins went from one.
  public var checkInMore: String? {
    switch kind {
    case "checkin.ignored": "Its check-ins are hidden, and no new ones are kept there."
    case "checkin.unignored": "Its check-ins show again."
    case "checkin.deleted" where all != true && place != nil:
      count.map { $0 == 1 ? "1 check-in went." : "\($0) check-ins went." }
    default: nil
    }
  }

  /// What this row can open. A check-in opens for anyone who can see the row;
  /// the rest are for a token that may read every note. A note deleted has
  /// nothing to open, and a reply filed by email names only its day.
  public var opens: ActivityTarget? {
    guard let day else { return nil }
    switch kind {
    case "checkin", "checkin.named":
      return checkin.map { .checkIn(day: day, id: $0) }
    case "note.added", "note.edited", "note.files", "description.added", "transcript.added":
      return note.map { .note(date: day, id: $0) }
    case "mail":
      return outcome == "filed" ? .day(day) : nil
    default:
      return nil
    }
  }
}

/// Where an activity row leads.
public enum ActivityTarget: Hashable, Sendable {
  case note(date: String, id: String)
  case day(String)
  case checkIn(day: String, id: String)
}

/// `GET /v1/upcoming/reminders`: the reminders each morning's email
/// carries, for the days ahead, with when that email is due. Only days with
/// a reminder are listed.
public struct Reminders: Codable, Sendable, Equatable {
  public var from: String
  public var through: String
  public var days: [ReminderDay]
}

public struct ReminderDay: Codable, Sendable, Equatable {
  public var date: String
  /// When that morning's email is due, with the account's offset that day.
  public var sendAt: String
  public var reminders: [Reminder]
}

/// One reminder, in the email's own words: `when` ("In 7 days") and `line`.
public struct Reminder: Codable, Sendable, Equatable {
  /// The Upcoming date's id.
  public var upcoming: String
  public var date: String
  public var when: String
  public var line: String
}

/// The one error shape: `{"error": {"code", "message"}}`.
struct ErrorBody: Codable, Sendable {
  struct Detail: Codable, Sendable {
    var code: String
    var message: String
    var field: String?
    /// A note's revision is a string, a check-in's a number: either reads, so
    /// the refusal's own words always come through.
    var revision: String?
    /// A remembered place's check-ins now, refusing a delete for another count.
    var count: Int?

    private enum CodingKeys: String, CodingKey { case code, message, field, revision, count }

    init(from decoder: Decoder) throws {
      let keys = try decoder.container(keyedBy: CodingKeys.self)
      code = try keys.decode(String.self, forKey: .code)
      message = try keys.decode(String.self, forKey: .message)
      field = try? keys.decodeIfPresent(String.self, forKey: .field)
      revision = (try? keys.decodeIfPresent(String.self, forKey: .revision))
        ?? (try? keys.decodeIfPresent(Int.self, forKey: .revision)).flatMap { $0.map(String.init) }
      count = try? keys.decodeIfPresent(Int.self, forKey: .count)
    }
  }
  var error: Detail
}

extension NoteDetail {
  /// A note is its place in the archive and its revision: enough to go to it,
  /// which is all a screen hashes one for.
  public func hash(into hasher: inout Hasher) {
    hasher.combine(date)
    hasher.combine(id)
    hasher.combine(revision)
  }
}
