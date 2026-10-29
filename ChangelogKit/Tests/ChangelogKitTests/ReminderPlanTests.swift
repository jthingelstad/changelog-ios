import Foundation
import Testing
@testable import ChangelogKit

@Suite struct ReminderPlanTests {
  static let answer = """
    {"from":"2026-10-29","through":"2026-11-11","days":[
      {"date":"2026-10-29","send_at":"2026-10-29T06:00:00-05:00",
       "reminders":[{"upcoming":"u-1","date":"2026-11-04","when":"In 6 days","line":"Mom turns 7.0.0. A major release."}]},
      {"date":"2026-11-03","send_at":"2026-11-03T06:00:00-06:00",
       "reminders":[{"upcoming":"u-1","date":"2026-11-04","when":"Tomorrow","line":"Mom turns 7.0.0. A major release."},
                    {"upcoming":"u-2","date":"2026-11-03","when":"Today","line":"Lake trip starts."}]}
    ]}
    """

  @Test func eachReminderComesWhenItsMorningsEmailIsDue() throws {
    let reminders = try APIClient.decoder.decode(Reminders.self, from: Data(Self.answer.utf8))
    // Half past six on the 29th: that morning's email has gone, so its
    // reminder is not caught up.
    let now = try Date("2026-10-29T11:30:00Z", strategy: .iso8601)
    let plan = ReminderPlan.plan(reminders, now: now)
    #expect(plan.map(\.id) == ["upcoming-reminder.2026-11-03.u-1", "upcoming-reminder.2026-11-03.u-2"])
    // After the clocks change: 6am Central is noon UTC on the 3rd.
    #expect(plan.first?.fireAt == (try Date("2026-11-03T12:00:00Z", strategy: .iso8601)))
    #expect(plan.first?.when == "Tomorrow")
    #expect(plan.last?.line == "Lake trip starts.")
    #expect(Set(plan.map(\.thread)) == ["upcoming-reminder.2026-11-03"])
  }

  @Test func theSoonestStayWithinTheLimit() throws {
    let days = (1...40).map { n in
      ReminderDay(date: "d\(n)", sendAt: "2026-12-\(String(format: "%02d", min(n, 28)))T06:00:00-06:00",
                  reminders: [Reminder(upcoming: "a", date: "x", when: "Today", line: "A"),
                              Reminder(upcoming: "b", date: "x", when: "Today", line: "B")])
    }
    let plan = ReminderPlan.plan(Reminders(from: "x", through: "y", days: days), now: .distantPast)
    #expect(plan.count == ReminderPlan.limit)
    #expect(plan.first?.id == "upcoming-reminder.d1.a")
    #expect(zip(plan, plan.dropFirst()).allSatisfy { $0.fireAt <= $1.fireAt })
  }

  @Test func anUnreadableMomentIsLeftOut() {
    let day = ReminderDay(date: "2026-11-01", sendAt: "soon", reminders: [Reminder(upcoming: "a", date: "x", when: "Today", line: "A")])
    #expect(ReminderPlan.plan(Reminders(from: "x", through: "y", days: [day]), now: .distantPast).isEmpty)
  }

  @Test func theClientAsksForTwoWeeks() async throws {
    StubProtocol.set("reminders.test", .init(status: 200, body: Self.answer))
    let reminders = try await stubbedClient("reminders.test").reminders()
    #expect(reminders.days.count == 2)
    #expect(reminders.days.last?.sendAt == "2026-11-03T06:00:00-06:00")
    let url = StubProtocol.requests("reminders.test").first?.url
    #expect(url?.path() == "/v1/upcoming/reminders")
    #expect(url?.query == "days=14")
  }
}
