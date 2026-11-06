import Foundation
import Testing
@testable import ChangelogKit

/// What an activity row says under its headline, and what it opens.
@Suite struct ActivityRowTests {
  static func row(_ kind: String, via: String? = "web", day: String? = "2026-10-30", note: String? = "n-1",
                  outcome: String? = nil) -> ActivityItem {
    ActivityItem(id: "row", at: "2026-10-30T14:00:00.000Z", kind: kind, via: via, day: day, note: note, outcome: outcome)
  }

  @Test func aReminderWentOutInTheDailyEmail() {
    #expect(Self.row("reminder", via: "email", note: nil).detail == "in the daily email · 2026-10-30")
  }

  @Test func aNoteByEmailStillSaysSo() {
    #expect(Self.row("note.added", via: "email").detail == "by email · 2026-10-30")
    #expect(Self.row("mail", via: "email", note: nil, outcome: "filed").detail == "by email · 2026-10-30")
  }

  @Test(arguments: ["note.added", "note.edited", "note.files", "description.added", "transcript.added"])
  func aRowAboutANoteOpensIt(kind: String) {
    #expect(Self.row(kind).opens == .note(date: "2026-10-30", id: "n-1"))
  }

  @Test func aReplyFiledOpensItsDay() {
    #expect(Self.row("mail", via: "email", note: nil, outcome: "filed").opens == .day("2026-10-30"))
  }

  @Test(arguments: ["note.deleted", "email.sent", "reminder", "badge.earned", "import.notes", "upcoming.added", "reads", "signin"])
  func aRowAboutAnythingElseStaysStill(kind: String) {
    #expect(Self.row(kind).opens == nil)
  }

  @Test func aReplyNotFiledHasNothingToOpen() {
    #expect(Self.row("mail", via: "email", note: nil, outcome: "not-filed").opens == nil)
    #expect(Self.row("mail", via: "email", note: nil, outcome: "failed").opens == nil)
  }

  @Test func aRowMissingItsNoteOrDayStaysStill() {
    #expect(Self.row("note.added", note: nil).opens == nil)
    #expect(Self.row("note.added", day: nil).opens == nil)
  }
}
