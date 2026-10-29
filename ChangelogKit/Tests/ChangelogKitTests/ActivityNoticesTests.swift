import Foundation
import Testing
@testable import ChangelogKit

@Suite struct ActivityNoticesTests {
  static let me = "Changelog on a test phone"

  static func row(_ id: String, _ kind: String, via: String? = nil, token: String? = nil, client: String? = nil,
                  outcome: String? = nil, name: String? = nil) -> ActivityItem {
    ActivityItem(id: "2026-10-29T14:00:\(id)Z#\(kind)#\(id)", at: "2026-10-29T14:00:00.000Z", kind: kind, via: via, client: client,
                 token: token, day: "2026-10-29", version: "4.5.137", note: nil, files: nil, outcome: outcome, name: name, title: nil)
  }

  @Test func thisPhonesOwnNotesNeverNotify() {
    let own = Self.row("01", "note.added", via: "token", token: Self.me, client: "Changelog")
    #expect(ActivityNotices.isOwn(own, tokenName: Self.me))
    #expect(ActivityNotices.kind(of: own, tokenName: Self.me) == nil)
    // This token through something else on the phone (a share sheet, a
    // Shortcut) is still this phone.
    let shared = Self.row("02", "note.added", via: "token", token: Self.me, client: "Shortcuts")
    #expect(ActivityNotices.kind(of: shared, tokenName: Self.me) == nil)
    // A badge this phone's note earned shows as the app's own toast.
    let badge = Self.row("03", "badge.earned", via: "token", token: Self.me, client: "Changelog", name: "API release")
    #expect(ActivityNotices.kind(of: badge, tokenName: Self.me) == nil)
  }

  @Test func anotherTokenIsSomeoneElseEvenFromChangelog() {
    // Changelog on another device has its own token, and so its own name;
    // a client name alone decides nothing.
    let other = Self.row("04", "note.added", via: "token", token: "Changelog on the iPad", client: "Changelog")
    #expect(ActivityNotices.kind(of: other, tokenName: Self.me) == .others)
    let terminal = Self.row("05", "note.added", via: "token", token: "Terminal", client: "curl")
    #expect(ActivityNotices.kind(of: terminal, tokenName: Self.me) == .others)
  }

  @Test func eachKindMapsAndTheDailyEmailNeverDoes() {
    let map = { (item: ActivityItem) in ActivityNotices.kind(of: item, tokenName: Self.me) }
    #expect(map(Self.row("10", "note.added", via: "assistant", client: "Claude")) == .others)
    #expect(map(Self.row("11", "import.notes", via: "import")) == .others)
    #expect(map(Self.row("12", "mail", via: "reply", outcome: "filed")) == .others)
    #expect(map(Self.row("13", "mail", via: "reply", outcome: "not-filed")) == .problems)
    #expect(map(Self.row("14", "mail", via: "address", outcome: "failed")) == .problems)
    #expect(map(Self.row("15", "status.stopped", via: "email")) == .problems)
    #expect(map(Self.row("16", "connection.removed", via: "web", token: "Terminal", client: "Terminal")) == .problems)
    #expect(map(Self.row("17", "badge.earned", via: "web", name: "Streak")) == .badges)
    // Never: the email going out, its reminders, the owner on the web, and
    // whatever else the log holds.
    #expect(map(Self.row("20", "email.sent", via: "email")) == nil)
    #expect(map(Self.row("21", "reminder", via: "email")) == nil)
    #expect(map(Self.row("22", "note.added", via: "web")) == nil)
    #expect(map(Self.row("23", "note.edited", via: "assistant", client: "Claude")) == nil)
    #expect(map(Self.row("24", "settings.changed", via: "web")) == nil)
    #expect(map(Self.row("25", "reads", via: "assistant", client: "Claude")) == nil)
  }

  @Test func onlyTheKindsChosenInOrderAndWithoutWords() {
    // Newest first, as the API answers.
    let page = [
      Self.row("33", "badge.earned", via: "web", name: "Streak"),
      Self.row("32", "mail", via: "reply", outcome: "not-filed"),
      Self.row("31", "note.added", via: "token", token: Self.me, client: "Changelog"),
      Self.row("30", "note.added", via: "assistant", client: "Claude"),
    ]
    let notices = ActivityNotices.notices(for: page, tokenName: Self.me, wanted: [.others, .problems])
    #expect(notices.map(\.kind) == [.others, .problems])
    #expect(notices.first?.title == "Added to 4.5.137")
    #expect(notices.first?.body == "Claude added a note.")
    #expect(notices.last?.title == "An email wasn't filed")
    #expect(notices.allSatisfy { $0.id.hasPrefix(ActivityNotices.prefix) })
    #expect(ActivityNotices.notices(for: page, tokenName: Self.me, wanted: []).isEmpty)
  }

  @Test func manyOfAKindComeAsOne() {
    let page = (40..<46).reversed().map { Self.row("\($0)", "note.added", via: "assistant", client: "Claude") }
    let notices = ActivityNotices.notices(for: page, tokenName: Self.me, wanted: [.others])
    #expect(notices.count == 1)
    #expect(notices.first?.title == "6 notes from elsewhere")
    #expect(notices.first?.id == "activity.others.\(page.first!.id)")
  }

  @Test func theCursorMovesToTheNewestRead() {
    let page = [Self.row("51", "mail", via: "reply", outcome: "filed"), Self.row("50", "note.added", via: "web")]
    #expect(ActivityNotices.cursor(after: page, previous: "old") == page.first?.id)
    #expect(ActivityNotices.cursor(after: [], previous: "old") == "old")
  }

  @Test func theReadAsksOnlyForWhatCanNotify() async throws {
    StubProtocol.set("notices.test", .init(status: 200, body: #"{"items":[],"next":null}"#))
    _ = try await stubbedClient("notices.test").activity(after: "2026-10-29T14:00:00.000Z#note.added#t-1",
                                                         kinds: ActivityNotices.families, limit: 100)
    let query = StubProtocol.requests("notices.test").first?.url?.query(percentEncoded: false) ?? ""
    #expect(query.contains("kinds=note,mail,import,badge,status,connection"))
    #expect(query.contains("after=2026-10-29T14:00:00.000Z#note.added#t-1"))
  }
}
