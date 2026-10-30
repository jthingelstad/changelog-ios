import BackgroundTasks
import ChangelogKit
import Foundation
import Observation
import UserNotifications

/// This phone's own notifications (0.3), with no push server: Upcoming
/// reminders, the daily prompt and activity notices, each off until the
/// person turns it on in Settings. Reminders and prompts are scheduled ahead
/// from the last read (`NotificationPlan`), topped up on opening the app and
/// whenever iOS lets it refresh in the background; activity notices are
/// shown as a background refresh finds them.
@MainActor
enum PhoneReminders {
  static let refreshTask = "com.yourversionnumber.changelog.reminders"
  private static let presenter = Presenter()

  /// Shows a notification that comes while Changelog is open, too, and
  /// opens the tab a tapped one names.
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

  /// Brings what is waiting in line with a plan, for as long as `wanted`
  /// holds: this app's ids the plan dropped go, and each planned one is
  /// added under its own id, which replaces any waiting with that id. With
  /// `reminders` nil (the read failed), the reminders waiting stay as they
  /// are and the prompts fit around them.
  static func schedule(reminders: [PlannedReminder]?, prompts: [PlannedNotification], now: Date = .now,
                       while wanted: () -> Bool) async
  {
    let center = UNUserNotificationCenter.current()
    let pending = await center.pendingNotificationRequests().map(\.identifier)
    let kept = reminders == nil ? pending.filter { $0.hasPrefix(ReminderPlan.prefix) }.count : 0
    let plan = NotificationPlan.plan(reminders: reminders, prompts: prompts, keptReminders: kept)
    guard wanted() else { return }
    center.removePendingNotificationRequests(withIdentifiers: NotificationPlan.stale(pending: pending, plan: plan,
                                                                                     keepingReminders: reminders == nil))
    for planned in plan {
      // Turned off or changed midway: the update that changed it puts
      // things right.
      guard wanted() else { return }
      let content = UNMutableNotificationContent()
      content.title = planned.title
      content.subtitle = planned.subtitle
      content.body = planned.body
      content.threadIdentifier = planned.thread
      content.sound = .default
      content.userInfo = ["tab": planned.opens]
      // A moment, not a clock time, so a trip to another time zone still
      // brings it with the email.
      let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, planned.fireAt.timeIntervalSince(now)), repeats: false)
      try? await center.add(UNNotificationRequest(identifier: planned.id, content: content, trigger: trigger))
    }
  }

  /// Takes back every reminder and prompt this app scheduled.
  static func clear() async {
    let center = UNUserNotificationCenter.current()
    let ids = await center.pendingNotificationRequests().map(\.identifier)
      .filter { id in NotificationPlan.prefixes.contains(where: id.hasPrefix) }
    center.removePendingNotificationRequests(withIdentifiers: ids)
  }

  /// Takes away every notification of this app's still in Notification
  /// Center, at sign-out, so none of an account's dates stay behind.
  static func clearShown() {
    UNUserNotificationCenter.current().removeAllDeliveredNotifications()
  }

  /// Takes back waiting notifications by id.
  static func takeBack(_ ids: [String]) {
    UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
  }

  /// Shows activity notices now. They hold no note's words.
  static func show(_ notices: [ActivityNotice]) async {
    let center = UNUserNotificationCenter.current()
    for notice in notices {
      let content = UNMutableNotificationContent()
      content.title = notice.title
      content.body = notice.body
      content.threadIdentifier = ActivityNotices.prefix + notice.kind.rawValue
      content.sound = .default
      content.userInfo = ["tab": "activity"]
      try? await center.add(UNNotificationRequest(identifier: notice.id, content: content, trigger: nil))
    }
  }

  /// Asks iOS for a background refresh, no sooner than `after`. iOS decides
  /// when, or whether; opening the app always reads again.
  static func askForRefresh(after: TimeInterval = 6 * 3600) {
    let request = BGAppRefreshTaskRequest(identifier: refreshTask)
    request.earliestBeginDate = Date(timeIntervalSinceNow: after)
    try? BGTaskScheduler.shared.submit(request)
  }

  static func cancelRefresh() {
    BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: refreshTask)
  }

  private final class Presenter: NSObject, UNUserNotificationCenterDelegate, Sendable {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
      [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
      let tab = response.notification.request.content.userInfo["tab"] as? String
      await MainActor.run { AppRoute.shared.tab = tab }
    }
  }
}
