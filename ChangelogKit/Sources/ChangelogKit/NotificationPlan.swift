import Foundation

/// One notification the phone schedules for itself: an Upcoming reminder or
/// the daily prompt. Ids are the same for the same thing on the same day, so
/// a top-up replaces what it scheduled before rather than adding to it.
public struct PlannedNotification: Sendable, Equatable {
  public enum Kind: Int, Sendable, Comparable {
    // At the same moment, a reminder comes before the prompt.
    case reminder, prompt
    public static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }
  }

  public var id: String
  public var kind: Kind
  public var fireAt: Date
  public var title: String
  public var subtitle: String
  public var body: String
  public var thread: String
  /// The tab a tap opens: `upcoming` or `log`.
  public var opens: String

  public init(_ reminder: PlannedReminder) {
    id = reminder.id
    kind = .reminder
    fireAt = reminder.fireAt
    title = "Upcoming"
    subtitle = reminder.when
    body = reminder.line
    thread = reminder.thread
    opens = "upcoming"
  }

  public init(prompt id: String, fireAt: Date, body: String) {
    self.id = id
    kind = .prompt
    self.fireAt = fireAt
    title = ""
    subtitle = ""
    self.body = body
    thread = DailyPrompt.prefix
    opens = "log"
  }
}

/// The daily prompt (Jamie's call 3: off by default): "You're 4.5.137
/// today. What changed?" at the moment each morning's email is due, which
/// opens Log. The versions are the server's, from `/v1/me`'s `days`; the
/// phone works out only when the account's send time comes on each day.
public enum DailyPrompt {
  public static let prefix = "daily-prompt."

  /// The prompt's id for a day, the same on every top-up.
  public static func id(_ day: String) -> String { prefix + day }

  public static func text(version: String) -> String {
    "You're \(version) today. What changed?"
  }

  /// One prompt for each day `/v1/me` lists whose moment is still ahead,
  /// except today once something was written today. A day the reminders
  /// read also lists takes its `send_at` from there, so the two agree.
  public static func plan(_ me: Me, reminders: Reminders? = nil, now: Date) -> [PlannedNotification] {
    guard let zone = TimeZone(identifier: me.tz) else { return [] }
    var sendAt: [String: Date] = [:]
    for day in reminders?.days ?? [] {
      if let at = try? Date(day.sendAt, strategy: .iso8601) { sendAt[day.date] = at }
    }
    var days = me.days
    if !days.contains(where: { $0.date == me.today }) { days.insert(DayVersion(date: me.today, version: me.version), at: 0) }
    var seen = Set<String>()
    return days.compactMap { day in
      guard seen.insert(day.date).inserted else { return nil }
      if day.date == me.today && me.wroteToday { return nil }
      guard let at = sendAt[day.date] ?? moment(day: day.date, time: me.sendTime, in: zone), at > now else { return nil }
      return PlannedNotification(prompt: id(day.date), fireAt: at, body: text(version: day.version))
    }
  }

  /// When a local day's clock first shows a time ("06:30") in a zone. A
  /// time the clock skips is the change itself, and a time it shows twice
  /// the first, as Release Notes' own `localMoment` reads it.
  public static func moment(day: String, time: String, in zone: TimeZone) -> Date? {
    guard let (y, m, d) = UpcomingDraft.parse(day) else { return nil }
    let clock = time.split(separator: ":").compactMap { Int($0) }
    guard clock.count == 2, (0...23).contains(clock[0]), (0...59).contains(clock[1]) else { return nil }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    guard let start = calendar.date(from: DateComponents(year: y, month: m, day: d)),
          let at = calendar.nextDate(after: start.addingTimeInterval(-1), matching: DateComponents(hour: clock[0], minute: clock[1]),
                                     matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward)
    else { return nil }
    let shown = calendar.dateComponents([.year, .month, .day], from: at)
    return shown.year == y && shown.month == m && shown.day == d ? at : nil
  }
}

/// Which notifications to keep waiting. iOS keeps at most 64 waiting
/// notifications an app (the soonest, silently dropping the rest), so
/// reminders and prompts share one budget across the rolling window of
/// about two weeks, the soonest first, topped up on every launch and
/// background refresh. Activity notices are delivered at once, so they
/// barely wait; the few left over are their room.
public enum NotificationPlan {
  public static let limit = 60
  /// Every id this app schedules starts with one of these, so a top-up
  /// touches its own and nothing else.
  public static let prefixes = [ReminderPlan.prefix, DailyPrompt.prefix]

  /// The plan from the latest reminders read, or with `reminders` nil (the
  /// read failed), the prompts alone, around the `keptReminders` already
  /// waiting, which stay as they were.
  public static func plan(reminders: [PlannedReminder]?, prompts: [PlannedNotification], keptReminders: Int = 0,
                          limit: Int = NotificationPlan.limit) -> [PlannedNotification]
  {
    let budget = reminders == nil ? max(0, limit - keptReminders) : limit
    let all = (reminders ?? []).map(PlannedNotification.init) + prompts
    return Array(all.sorted { ($0.fireAt, $0.kind, $0.id) < ($1.fireAt, $1.kind, $1.id) }.prefix(budget))
  }

  /// The waiting ids to take back: this app's own that the plan no longer
  /// holds. Reminders kept from before (a failed read) stay.
  public static func stale(pending: [String], plan: [PlannedNotification], keepingReminders: Bool = false) -> [String] {
    let keep = Set(plan.map(\.id))
    return pending.filter { id in
      guard prefixes.contains(where: id.hasPrefix), !keep.contains(id) else { return false }
      return !(keepingReminders && id.hasPrefix(ReminderPlan.prefix))
    }
  }
}
