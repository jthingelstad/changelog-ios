import Foundation
import Testing
@testable import ChangelogKit

/// Upcoming against the dev server's fictional account (see DevServerTests):
/// a destination found by a dry run that saves nothing, then an add, a
/// change, a stale change refused, a resend that makes no second date, and a
/// delete. Skips without `CHANGELOG_DEV_TOKEN`.
@Suite(.enabled(if: DevServer.enabled), .serialized)
struct UpcomingDevServerTests {
  @Test func dryRunAddChangeAndDelete() async throws {
    let client = DevServer.client()
    let before = try await client.upcoming()
    let today = before.today
    let start = try #require(Self.day(today, plus: 20)), end = try #require(Self.day(today, plus: 23))

    var draft = UpcomingDraft(kind: .trip, today: today)
    draft.title = "Dev test trip"
    draft.start = start
    draft.end = end
    draft.place = "Paris"
    draft.tag = "devtest"

    // The dry run finds the city and saves nothing.
    let check = try await client.saveUpcoming(try draft.placeCheck(editing: nil).get(), idempotencyKey: nil)
    #expect(check.dryRun)
    let found = try #require(check.saved?.fields.place)
    #expect(found.contains("France"))
    #expect(try await client.upcoming().entries.count == before.entries.count)

    // Saved, and sent again under the same key: one date.
    let add = try draft.batch(editing: nil).get()
    let key = UUID().uuidString.lowercased()
    let saved = try #require(try await client.saveUpcoming(add, idempotencyKey: key).saved)
    let again = try #require(try await client.saveUpcoming(add, idempotencyKey: key).saved)
    #expect(again.id == saved.id)
    #expect(saved.fields.reminders == [14, 1, 0])
    #expect(saved.fields.endDate == end)
    #expect(try await client.upcoming().entries.filter { $0.id == saved.id }.count == 1)

    // A change from the revision read, then one from the old revision.
    var edit = UpcomingDraft(entry: saved, today: today)
    edit.reminders = [7, 0]
    let change = try edit.batch(editing: saved).get()
    let changed = try #require(try await client.saveUpcoming(change, idempotencyKey: UUID().uuidString.lowercased()).saved)
    #expect(changed.id == saved.id)
    #expect(changed.revision > saved.revision)
    #expect(changed.fields.reminders == [7, 0])
    do {
      _ = try await client.saveUpcoming(change, idempotencyKey: UUID().uuidString.lowercased())
      Issue.record("a stale change was saved")
    } catch {
      #expect(error.code == "revision_mismatch")
    }

    // Deleted, and deleting again is not_found.
    try await client.deleteUpcoming(id: changed.id, revision: changed.revision, idempotencyKey: UUID().uuidString.lowercased())
    #expect(try await client.upcoming().entries.contains { $0.id == saved.id } == false)
    do {
      try await client.deleteUpcoming(id: changed.id, revision: changed.revision, idempotencyKey: UUID().uuidString.lowercased())
      Issue.record("deleted twice")
    } catch {
      #expect(error.code == "not_found")
    }
  }

  static func day(_ day: String, plus days: Int) -> String? {
    guard let (y, m, d) = UpcomingDraft.parse(day) else { return nil }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .gmt
    guard let start = calendar.date(from: DateComponents(year: y, month: m, day: d)),
          let date = calendar.date(byAdding: .day, value: days, to: start) else { return nil }
    let c = calendar.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
  }
}

/// Activity notices from the dev server's real rows: a note this token adds
/// after the cursor reads as the phone's own, so nothing is shown.
@Suite(.enabled(if: DevServer.enabled), .serialized)
struct ActivityNoticesDevServerTests {
  @Test func thisTokensNoteAfterTheCursorNeverNotifies() async throws {
    let client = DevServer.client()
    let me = try await client.me()
    let start = try await client.activity(kinds: ActivityNotices.families, limit: 1)
    let cursor = try #require(start.items.first?.id)
    _ = try await client.createNote(NoteRequest(text: "From this phone #devtest"), idempotencyKey: UUID().uuidString.lowercased())
    let page = try await client.activity(after: cursor, kinds: ActivityNotices.families, limit: 100)
    let own = try #require(page.items.first { $0.kind == "note.added" })
    #expect(own.via == "token")
    #expect(ActivityNotices.isOwn(own, tokenName: me.token.name))
    #expect(ActivityNotices.notices(for: page.items, tokenName: me.token.name, wanted: Set(ActivityNoticeKind.allCases))
      .allSatisfy { $0.kind != .others })
    #expect(ActivityNotices.cursor(after: page.items, previous: cursor) != cursor)
  }
}
