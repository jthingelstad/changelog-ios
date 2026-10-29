import Foundation

/// The kinds of activity a phone can be told about, each turned on by
/// itself in the app's Settings (off until then).
public enum ActivityNoticeKind: String, Codable, Sendable, CaseIterable, Identifiable {
  /// Notes added by someone else: an agent, another token, an import, an
  /// email reply.
  case others
  /// An email that wasn't filed, the email stopping, a connection ending.
  case problems
  case badges

  public var id: String { rawValue }
}

/// A notification for one activity row, or for several of one kind. It never
/// carries a note's words: the activity log has none to give.
public struct ActivityNotice: Sendable, Equatable {
  public var id: String
  public var kind: ActivityNoticeKind
  public var title: String
  public var body: String
}

/// Activity notifications, read from `GET /v1/activity?after=<last seen>`
/// in background refresh, so iOS decides when. Never this phone's own notes
/// or badges (the app shows those itself), and never the daily email going
/// out or the reminders it carried.
public enum ActivityNotices {
  public static let prefix = "activity."
  /// The families a notice can come from, so each read stays small.
  public static let families = ["note", "mail", "import", "badge", "status", "connection"]
  /// More than this many of one kind from one read come as one notice.
  public static let perKind = 3

  /// Whether a row came through this phone's own token. The token's name
  /// (`/v1/me`'s `token.name`) is what every row a token writes carries;
  /// `client` is only what a User-Agent claimed, so it labels and never
  /// decides. A share sheet or Shortcut on this phone using the same token
  /// counts as this phone. Should another token have the same name, its
  /// notes stay quiet too: a missed notice, never a false one.
  public static func isOwn(_ item: ActivityItem, tokenName: String) -> Bool {
    item.via == "token" && item.token == tokenName
  }

  /// Which notice a row is, if any.
  public static func kind(of item: ActivityItem, tokenName: String) -> ActivityNoticeKind? {
    if isOwn(item, tokenName: tokenName) { return nil }
    switch item.kind {
    case "note.added":
      // The web is the owner at a keyboard; email replies are mail rows.
      return ["assistant", "token", "import"].contains(item.via ?? "") ? .others : nil
    case "import.notes":
      return .others
    case "mail":
      switch item.outcome {
      case "filed": return .others
      case "not-filed", "failed": return .problems
      default: return nil
      }
    case "badge.earned":
      return .badges
    case "status.stopped", "connection.removed":
      return .problems
    default:
      // email.sent, reminder and the rest never notify.
      return nil
    }
  }

  /// The notices for rows read newest first, oldest first so they arrive in
  /// order, only of the kinds wanted. A kind with more than `perKind` rows
  /// comes as one notice instead.
  public static func notices(for items: [ActivityItem], tokenName: String, wanted: Set<ActivityNoticeKind>) -> [ActivityNotice] {
    let rows = items.reversed().compactMap { item -> (ActivityItem, ActivityNoticeKind)? in
      guard let kind = kind(of: item, tokenName: tokenName), wanted.contains(kind) else { return nil }
      return (item, kind)
    }
    var out: [ActivityNotice] = []
    for kind in ActivityNoticeKind.allCases {
      let mine = rows.filter { $0.1 == kind }
      guard let newest = mine.last?.0 else { continue }
      if mine.count > perKind {
        out.append(summary(kind, count: mine.count, newest: newest))
      } else {
        out += mine.map { notice(for: $0.0, kind: $0.1) }
      }
    }
    return out
  }

  /// Where the next read starts: the newest row read, or where it was.
  public static func cursor(after items: [ActivityItem], previous: String?) -> String? {
    items.first?.id ?? previous
  }

  static func notice(for item: ActivityItem, kind: ActivityNoticeKind) -> ActivityNotice {
    let id = prefix + item.id
    let version = item.version.map { " \($0)" } ?? ""
    switch item.kind {
    case "note.added":
      let who = item.via == "assistant" ? (item.client ?? "An agent") : item.via == "import" ? "An import" : (item.token ?? "Another token")
      return ActivityNotice(id: id, kind: kind, title: "Added to\(version)", body: "\(who) added a note.")
    case "import.notes":
      return ActivityNotice(id: id, kind: kind, title: "Notes imported", body: "An import added notes to your release notes.")
    case "mail" where kind == .others:
      return ActivityNotice(id: id, kind: kind, title: "Reply filed in\(version)", body: "An email you sent was filed.")
    case "mail":
      return ActivityNotice(id: id, kind: kind, title: "An email wasn't filed",
                            body: "Release Notes couldn't file an email. The mail log on the web says why.")
    case "badge.earned":
      return ActivityNotice(id: id, kind: kind, title: "Badge earned", body: item.name ?? "A new badge.")
    case "status.stopped":
      return ActivityNotice(id: id, kind: kind, title: "Your email stopped",
                            body: "The morning email isn't going out. Settings on the web says why.")
    default:
      let who = item.client ?? item.token ?? "A connection"
      return ActivityNotice(id: id, kind: kind, title: "A connection ended", body: "\(who) was disconnected.")
    }
  }

  static func summary(_ kind: ActivityNoticeKind, count: Int, newest: ActivityItem) -> ActivityNotice {
    let id = "\(prefix)\(kind.rawValue).\(newest.id)"
    switch kind {
    case .others:
      return ActivityNotice(id: id, kind: kind, title: "\(count) notes from elsewhere", body: "Open Activity to see them.")
    case .problems:
      return ActivityNotice(id: id, kind: kind, title: "\(count) things need a look", body: "Open Activity to see them.")
    case .badges:
      return ActivityNotice(id: id, kind: kind, title: "\(count) badges earned", body: "Open Activity to see them.")
    }
  }
}
