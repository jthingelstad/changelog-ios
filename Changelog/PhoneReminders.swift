import BackgroundTasks
import ChangelogKit
import Foundation
import UserNotifications

/// Upcoming reminders as this phone's own notifications (0.3). Off until the
/// person turns them on in Settings; then each read of
/// `/v1/upcoming/reminders` replaces everything scheduled before, on opening
/// the app and whenever iOS lets it refresh in the background. The server
/// sends nothing: the phone shows what the morning's email says, when it is
/// due.
@MainActor
enum PhoneReminders {
  static let refreshTask = "com.thingelstad.changelog.reminders"
  private static let presenter = Presenter()

  /// Shows a reminder that comes while Changelog is open, too.
  static func start() {
    UNUserNotificationCenter.current().delegate = presenter
  }

  static func ask() async -> Bool {
    (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
  }

  static func allowed() async -> Bool {
    let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    return status == .authorized || status == .provisional || status == .ephemeral
  }

  /// Replaces every reminder this app scheduled with the plan.
  static func schedule(_ plan: [PlannedReminder], now: Date = .now) async {
    let center = UNUserNotificationCenter.current()
    await clear()
    for planned in plan {
      let content = UNMutableNotificationContent()
      content.title = "Upcoming"
      content.subtitle = planned.when
      content.body = planned.line
      content.threadIdentifier = planned.thread
      content.sound = .default
      // A moment, not a clock time, so a trip to another time zone still
      // brings it with the email.
      let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, planned.fireAt.timeIntervalSince(now)), repeats: false)
      try? await center.add(UNNotificationRequest(identifier: planned.id, content: content, trigger: trigger))
    }
  }

  static func clear() async {
    let center = UNUserNotificationCenter.current()
    let ids = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(ReminderPlan.prefix) }
    center.removePendingNotificationRequests(withIdentifiers: ids)
  }

  /// Asks iOS for a background refresh some hours from now. iOS decides
  /// when, or whether; opening the app always reads again.
  static func askForRefresh() {
    let request = BGAppRefreshTaskRequest(identifier: refreshTask)
    request.earliestBeginDate = Date(timeIntervalSinceNow: 6 * 3600)
    try? BGTaskScheduler.shared.submit(request)
  }

  static func cancelRefresh() {
    BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: refreshTask)
  }

  private final class Presenter: NSObject, UNUserNotificationCenterDelegate, Sendable {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
      [.banner, .list, .sound]
    }
  }
}
