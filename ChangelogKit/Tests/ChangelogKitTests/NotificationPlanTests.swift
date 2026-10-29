import Foundation
import Testing
@testable import ChangelogKit

@Suite struct NotificationPlanTests {
  static let chicago = TimeZone(identifier: "America/Chicago")!

  /// The dev server's kind of account: versions as the server lists them.
  static func me(today: String = "2026-10-29", wroteToday: Bool = false, days: Int = 14) -> Me {
    let dates = (0..<days).map { i in
      Calendar(identifier: .gregorian).date(byAdding: .day, value: i, to: try! Date("\(today)T12:00:00Z", strategy: .iso8601))!
        .formatted(.iso8601.year().month().day())
    }
    return Me(today: today, version: "4.5.137", tz: "America/Chicago", sendTime: "06:30", wroteToday: wroteToday, streak: 3,
              pausedUntil: nil, status: "active", showBadges: true,
              days: dates.enumerated().map { DayVersion(date: $1, version: "4.5.\(137 + $0)") },
              token: TokenInfo(name: "Changelog on a test phone", scopes: ["notes:write", "upcoming", "activity"], expiresAt: nil),
              apiVersion: "1.2.0")
  }

  @Test func theSendTimeOnEachLocalDay() throws {
    // Before the clocks change, 06:30 Central is 11:30 UTC; after, 12:30.
    #expect(DailyPrompt.moment(day: "2026-10-29", time: "06:30", in: Self.chicago) == (try Date("2026-10-29T11:30:00Z", strategy: .iso8601)))
    #expect(DailyPrompt.moment(day: "2026-11-03", time: "06:30", in: Self.chicago) == (try Date("2026-11-03T12:30:00Z", strategy: .iso8601)))
    // A time the clock skips is the change itself, as the server reads it.
    #expect(DailyPrompt.moment(day: "2027-03-14", time: "02:30", in: Self.chicago) == (try Date("2027-03-14T08:00:00Z", strategy: .iso8601)))
    // A time it shows twice is the first.
    #expect(DailyPrompt.moment(day: "2026-11-01", time: "01:30", in: Self.chicago) == (try Date("2026-11-01T06:30:00Z", strategy: .iso8601)))
    #expect(DailyPrompt.moment(day: "2026-10-29", time: "6:30am", in: Self.chicago) == nil)
  }

  @Test func onePromptADayWithTheServersVersion() throws {
    let now = try Date("2026-10-29T09:00:00Z", strategy: .iso8601)
    let prompts = DailyPrompt.plan(Self.me(), now: now)
    #expect(prompts.count == 14)
    #expect(prompts.first?.id == "daily-prompt.2026-10-29")
    #expect(prompts.first?.body == "You're 4.5.137 today. What changed?")
    #expect(prompts.last?.body == "You're 4.5.150 today. What changed?")
    #expect(prompts.allSatisfy { $0.opens == "log" && $0.kind == .prompt })
    // Today's moment past, or something written today: tomorrow is first.
    #expect(DailyPrompt.plan(Self.me(), now: try Date("2026-10-29T12:00:00Z", strategy: .iso8601)).first?.id == "daily-prompt.2026-10-30")
    #expect(DailyPrompt.plan(Self.me(wroteToday: true), now: now).first?.id == "daily-prompt.2026-10-30")
  }

  @Test func aPromptTakesTheMomentTheRemindersReadGives() throws {
    let reminders = Reminders(from: "2026-10-29", through: "2026-11-11", days: [
      ReminderDay(date: "2026-10-30", sendAt: "2026-10-30T06:45:00-05:00", reminders: []),
    ])
    let prompts = DailyPrompt.plan(Self.me(), reminders: reminders, now: .distantPast)
    #expect(prompts.first { $0.id == "daily-prompt.2026-10-30" }?.fireAt == (try Date("2026-10-30T11:45:00Z", strategy: .iso8601)))
  }

  static func reminders(perDay: Int, days: Int = 14) -> [PlannedReminder] {
    let start = try! Date("2026-10-29T11:30:00Z", strategy: .iso8601)
    return (0..<days).flatMap { d in
      (0..<perDay).map { n in
        PlannedReminder(id: "upcoming-reminder.d\(String(format: "%02d", d)).u\(n)", fireAt: start.addingTimeInterval(Double(d) * 86400),
                        when: "Tomorrow", line: "A date.", thread: "upcoming-reminder.d\(d)")
      }
    }
  }

  @Test func remindersAndPromptsShareTheCapSoonestFirst() throws {
    let prompts = DailyPrompt.plan(Self.me(), now: .distantPast)
    let plan = NotificationPlan.plan(reminders: Self.reminders(perDay: 5), prompts: prompts)
    // 70 reminders and 14 prompts want room; iOS keeps 64 and four stay free.
    #expect(plan.count == NotificationPlan.limit)
    #expect(NotificationPlan.limit <= 64)
    #expect(zip(plan, plan.dropFirst()).allSatisfy { $0.fireAt <= $1.fireAt })
    // Each morning's reminders come before its prompt, at the same moment.
    #expect(plan.prefix(6).map(\.kind) == [.reminder, .reminder, .reminder, .reminder, .reminder, .prompt])
    #expect(plan.prefix(6).last?.fireAt == plan.first?.fireAt)
    #expect(Set(plan.map(\.id)).count == plan.count)
  }

  @Test func fewRemindersLeaveRoomForEveryPrompt() {
    let plan = NotificationPlan.plan(reminders: Self.reminders(perDay: 1, days: 3), prompts: DailyPrompt.plan(Self.me(), now: .distantPast))
    #expect(plan.count == 17)
    #expect(plan.filter { $0.kind == .prompt }.count == 14)
    #expect(plan.first { $0.kind == .reminder }?.opens == "upcoming")
  }

  @Test func aTopUpReplacesRatherThanAdds() throws {
    let me = Self.me()
    let first = NotificationPlan.plan(reminders: Self.reminders(perDay: 2, days: 3), prompts: DailyPrompt.plan(me, now: .distantPast))
    // A day later: the same things planned again keep their ids.
    let later = try Date("2026-10-30T12:00:00Z", strategy: .iso8601)
    let again = NotificationPlan.plan(reminders: Self.reminders(perDay: 2, days: 3).filter { $0.fireAt > later },
                                      prompts: DailyPrompt.plan(me, now: later))
    #expect(Set(again.map(\.id)).isSubset(of: Set(first.map(\.id))))
    // What is waiting and no longer planned goes; the rest is replaced in
    // place by id. Another app's or another feature's ids are never touched.
    let pending = first.map(\.id) + ["somebody-else.1"]
    let stale = NotificationPlan.stale(pending: pending, plan: again)
    #expect(Set(stale) == Set(first.map(\.id)).subtracting(again.map(\.id)))
    #expect(!stale.contains("somebody-else.1"))
    #expect(stale.contains("daily-prompt.2026-10-29"))
  }

  @Test func turningThePromptOffTakesBackOnlyPrompts() {
    let reminders = Self.reminders(perDay: 1, days: 2)
    let before = NotificationPlan.plan(reminders: reminders, prompts: DailyPrompt.plan(Self.me(), now: .distantPast))
    let after = NotificationPlan.plan(reminders: reminders, prompts: [])
    let stale = NotificationPlan.stale(pending: before.map(\.id), plan: after)
    #expect(stale.count == 14)
    #expect(stale.allSatisfy { $0.hasPrefix(DailyPrompt.prefix) })
  }

  @Test func aFailedReadKeepsTheRemindersWaitingAndPromptsFitAround() {
    let prompts = DailyPrompt.plan(Self.me(), now: .distantPast)
    let plan = NotificationPlan.plan(reminders: nil, prompts: prompts, keptReminders: 50)
    #expect(plan.count == 10)
    #expect(plan.allSatisfy { $0.kind == .prompt })
    #expect(plan.first?.id == "daily-prompt.2026-10-29")
    let pending = Self.reminders(perDay: 1, days: 3).map(\.id) + prompts.map(\.id)
    let stale = NotificationPlan.stale(pending: pending, plan: plan, keepingReminders: true)
    #expect(stale.count == 4)
    #expect(stale.allSatisfy { $0.hasPrefix(DailyPrompt.prefix) })
  }
}
