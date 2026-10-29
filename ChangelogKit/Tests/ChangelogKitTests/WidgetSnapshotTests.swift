import Foundation
import Testing
@testable import ChangelogKit

@Suite struct WidgetSnapshotTests {
  private func me(wrote: Bool = true) -> Me {
    Me(today: "2026-10-29", version: "4.5.137", tz: "America/Chicago", sendTime: "06:30", wroteToday: wrote, streak: 12,
       pausedUntil: nil, status: "active", showBadges: true,
       days: [DayVersion(date: "2026-10-29", version: "4.5.137"), DayVersion(date: "2026-10-30", version: "4.5.138"),
              DayVersion(date: "2026-10-31", version: "4.6.0")],
       token: TokenInfo(name: "Changelog", scopes: ["notes:write"], expiresAt: nil), apiVersion: "1.0.0")
  }

  private func entry(_ next: String, _ title: String, through: String? = nil, kind: UpcomingKind = .event, status: String = "upcoming") -> UpcomingEntry {
    UpcomingEntry(id: UUID().uuidString, revision: 1, next: next, through: through, status: status, line: "\(title).",
                  fields: UpcomingFields(kind: kind, title: title, date: next))
  }

  /// A moment in Chicago, "2026-10-29T23:59:00".
  private func chicago(_ moment: String) throws -> Date {
    try Date.ISO8601FormatStyle(timeZone: TimeZone(identifier: "America/Chicago")!)
      .year().month().day().dateSeparator(.dash).time(includingFractionalSeconds: false).timeSeparator(.colon)
      .parse(moment)
  }

  @Test func eachDayStartsAtTheAccountsMidnightWithTheServersVersion() throws {
    let snapshot = WidgetSnapshot(me: me(), upcoming: nil)
    let days = snapshot.timeline(now: try chicago("2026-10-29T15:00:00"))
    #expect(days.map(\.date) == ["2026-10-29", "2026-10-30", "2026-10-31"])
    #expect(days.map(\.version) == ["4.5.137", "4.5.138", "4.6.0"])
    // 05:00 UTC is midnight in Chicago in October.
    #expect(days[1].start == Date(timeIntervalSince1970: 1_793_336_400))
    #expect(days[0].end == days[1].start)
    // Written today says nothing about tomorrow.
    #expect(days.map(\.wrote) == [true, false, false])
  }

  @Test func theDayTheClocksGoBackIsTwentyFiveHours() throws {
    var account = me()
    account.days.append(DayVersion(date: "2026-11-01", version: "4.6.1"))
    let days = WidgetSnapshot(me: account, upcoming: nil).timeline(now: try chicago("2026-10-29T15:00:00"))
    let sunday = try #require(days.last)
    #expect(sunday.date == "2026-11-01")
    #expect(sunday.end.timeIntervalSince(sunday.start) == 25 * 3600)
  }

  @Test func afterMidnightTheNextDayLeads() throws {
    let days = WidgetSnapshot(me: me(), upcoming: nil).timeline(now: try chicago("2026-10-30T00:01:00"))
    #expect(days.first?.date == "2026-10-30")
    #expect(days.first?.wrote == false)
  }

  @Test func oncePastTheLastListedDayItAsksForTheApp() throws {
    #expect(WidgetSnapshot(me: me(), upcoming: nil).timeline(now: try chicago("2026-10-31T23:59:00")).count == 1)
    #expect(WidgetSnapshot(me: me(), upcoming: nil).timeline(now: try chicago("2026-11-01T00:00:00")).isEmpty)
  }

  @Test func upcomingKeepsTheSoonestAndDropsThemAsTheyPass() throws {
    let entries = [entry("2026-11-11", "Mom turns 7.0.0", kind: .birthday), entry("2026-10-30", "Dentist"),
                   entry("2026-10-29", "Lake week", through: "2026-10-31", kind: .trip), entry("2026-12-01", "Recital"),
                   entry("2026-10-01", "Long gone", status: "past")]
    let snapshot = WidgetSnapshot(me: me(), upcoming: entries)
    #expect(snapshot.upcoming?.map(\.title) == ["Lake week", "Dentist", "Mom turns 7.0.0"])
    let days = snapshot.timeline(now: try chicago("2026-10-29T15:00:00"))
    #expect(days[0].upcoming?.map(\.title) == ["Lake week", "Dentist"])
    // The dentist is past on the 31st; the trip is still on.
    #expect(days[2].upcoming?.map(\.title) == ["Lake week", "Mom turns 7.0.0"])
  }

  @Test func aTokenWithoutUpcomingShowsNone() throws {
    let days = WidgetSnapshot(me: me(), upcoming: nil).timeline(now: try chicago("2026-10-29T15:00:00"))
    #expect(days.allSatisfy { $0.upcoming == nil })
  }

  @Test func keptInDefaults() throws {
    let defaults = try #require(UserDefaults(suiteName: "changelog-widget-" + UUID().uuidString))
    let snapshot = WidgetSnapshot(me: me(wrote: false), upcoming: [entry("2026-10-30", "Dentist")])
    snapshot.save(to: defaults)
    #expect(WidgetSnapshot.load(from: defaults) == snapshot)
    WidgetSnapshot.clear(from: defaults)
    #expect(WidgetSnapshot.load(from: defaults) == nil)
  }

  @Test func aNoteFiledElsewhereMarksTodayWritten() throws {
    let defaults = try #require(UserDefaults(suiteName: "changelog-widget-" + UUID().uuidString))
    WidgetSnapshot(me: me(wrote: false), upcoming: nil).save(to: defaults)
    // Filed to another day (a note dated back): today is no different.
    #expect(!WidgetSnapshot.filed(on: "2026-10-28", in: defaults))
    #expect(WidgetSnapshot.filed(on: "2026-10-29", in: defaults))
    #expect(WidgetSnapshot.load(from: defaults)?.wroteToday == true)
    #expect(!WidgetSnapshot.filed(on: "2026-10-29", in: defaults))
  }
}
