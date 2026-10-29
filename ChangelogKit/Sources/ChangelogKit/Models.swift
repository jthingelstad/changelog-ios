import Foundation

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

  /// The version for a local day the server listed in `days`, so a widget or
  /// an offline header can show tomorrow's number without the arithmetic.
  public func version(on date: String) -> String? {
    date == today ? version : days.first { $0.date == date }?.version
  }
}

public struct DayVersion: Codable, Sendable, Equatable {
  public var date: String
  public var version: String
}

public struct TokenInfo: Codable, Sendable, Equatable {
  public var name: String
  public var scopes: [String]
  public var expiresAt: String?
}

/// `POST /v1/notes`. `writtenAt` is the moment the words were typed, so a
/// note queued offline files to the day it was written.
public struct NoteRequest: Codable, Sendable, Equatable {
  public var text: String
  public var date: String?
  public var writtenAt: String?

  public init(text: String, date: String? = nil, writtenAt: String? = nil) {
    self.text = text
    self.date = date
    self.writtenAt = writtenAt
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
}

public struct Unlocked: Codable, Sendable, Equatable {
  public var key: String
  public var name: String
}

public struct NoteReceipt: Codable, Sendable, Equatable {
  public var note: NoteRef
  public var unlocked: [Unlocked]?
}

/// `GET /v1/notes/{date}/{id}`, for a note this token wrote.
public struct NoteDetail: Codable, Sendable, Equatable {
  public var id: String
  public var date: String
  public var text: String
  public var revision: String
  public var writtenAt: String?
  public var files: Int?
}

/// `GET /v1/tags`: the pinned list, then the most used in the last 30 days.
public struct Tags: Codable, Sendable, Equatable {
  public var pinned: [String]
  public var recent: [RecentTag]
  public var windowDays: Int?
}

public struct RecentTag: Codable, Sendable, Equatable {
  public var tag: String
  public var count: Int
  public var lastUsed: String?
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

  public var family: String { String(kind.split(separator: ".").first ?? Substring(kind)) }
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
    var revision: String?
  }
  var error: Detail
}
