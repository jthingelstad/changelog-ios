import Foundation

/// Upcoming reminders as the phone's own notifications, planned from the last
/// read of `GET /v1/upcoming/reminders` (Release Notes' guide, Building a
/// client): each one at the moment that morning's email is due, in the
/// email's words. Nothing about a date is worked out here, only which to keep:
/// a morning already past is never caught up, and when iOS's limit on
/// waiting notifications binds, the soonest stay.
public struct PlannedReminder: Sendable, Equatable {
  /// The same for a reminder on its morning, so each plan replaces the last.
  public var id: String
  public var fireAt: Date
  /// "Tomorrow", "In 7 days": the email's line above each reminder.
  public var when: String
  public var line: String
  /// A morning's reminders group together.
  public var thread: String
}

public enum ReminderPlan {
  /// Every planned notification's id starts with this, so the app replaces
  /// its own and nothing else.
  public static let prefix = "upcoming-reminder."
  /// How far ahead to read: two weeks, the guide's default.
  public static let days = 14
  /// iOS keeps 64 waiting notifications an app; this leaves room.
  public static let limit = 60

  public static func plan(_ reminders: Reminders, now: Date) -> [PlannedReminder] {
    var planned: [PlannedReminder] = []
    for day in reminders.days {
      guard let at = try? Date(day.sendAt, strategy: .iso8601), at > now else { continue }
      for reminder in day.reminders {
        planned.append(PlannedReminder(
          id: "\(prefix)\(day.date).\(reminder.upcoming)", fireAt: at,
          when: reminder.when, line: reminder.line, thread: "\(prefix)\(day.date)"))
      }
    }
    planned.sort { ($0.fireAt, $0.id) < ($1.fireAt, $1.id) }
    return Array(planned.prefix(limit))
  }
}
