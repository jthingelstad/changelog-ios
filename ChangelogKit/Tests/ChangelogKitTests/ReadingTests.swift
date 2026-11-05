import Foundation
import Testing
@testable import ChangelogKit

/// Reading the notes: the shapes as `contracts/api-surface.json` in Release
/// Notes gives them, and trading a token for one that may read.
struct ReadingTests {
  private func client(_ host: String) -> APIClient {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubProtocol.self]
    return APIClient(baseURL: URL(string: "https://\(host)")!, token: "rn_" + String(repeating: "A", count: 43),
                     userAgent: "Changelog/0.1", session: URLSession(configuration: config))
  }

  private static let wholeNote = """
    {"id":"w-1","date":"2026-11-04","version":"4.5.143","text":"A **long** day at https://example.com #lake",
     "revision":"r1","written_at":"2026-11-04T08:15:00-06:00","files":2,
     "media":[{"n":1,"kind":"image","type":"image/jpeg","name":"dock.jpg","size":1000,
               "thumb":{"type":"image/jpeg","width":320,"height":240,"url":"https://files.test/t1"},
               "transcript":null,"description":"A dock at dusk","url":"https://files.test/1","expires_in":600},
              {"n":3,"kind":"audio","type":"audio/mp4","name":null,"size":2000,"thumb":null,
               "transcript":"Some words","description":null,"writing":false}],
     "token":null,"source":"web","mine":false,"tags":["lake"],"markup":"rich",
     "parts":["A **long** day at ",{"url":"https://example.com","label":"Example","site":"example.com"}," ",{"tag":"lake","text":"#lake"},{"later":"kind"}],
     "place":{"label":"Lake Harriet, Minneapolis","map":null,"venue":"Lake Harriet","lat":44.9,"lon":-93.3},
     "no_place":false,"edited_at":null,"tz":"America/Chicago","late":false,"author":"user","client":null,"from":null,"attachments":0,
     "added_later":"ignored"}
    """

  @Test func decodesTheTimeline() throws {
    let json = """
      {"today":"2026-11-05","tz":"America/Chicago","next":"2026-10-01",
       "weather_credit":"Weather by someone",
       "days":[{"date":"2026-11-04","version":"4.5.143","place":null,
                "around":{"label":"Minneapolis","from":"home"},
                "weather":{"line":"Cloudy, 8 degrees","high_c":8,"low_c":2,"code":3,"city":"Minneapolis"},
                "notes_total":3,"files":1,"emailed":true,"paused":false},
               {"date":"2026-11-03","version":"4.5.142","place":{"label":"Lake Harriet"},"around":null,"weather":null,
                "notes_total":0,"files":0,"emailed":false,"paused":true}]}
      """
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    let list = try decoder.decode(DayList.self, from: Data(json.utf8))
    #expect(list.days.map(\.notesTotal) == [3, 0])
    #expect(list.days[0].weather?.line == "Cloudy, 8 degrees")
    #expect(list.days[0].around?.from == "home")
    #expect(list.days[1].place?.label == "Lake Harriet")
    #expect(list.next == "2026-10-01")
    #expect(list.weatherCredit == "Weather by someone")
  }

  @Test func decodesADayWhoseTodayIsAYesOrNo() throws {
    let json = """
      {"date":"2026-11-04","version":"4.5.143","place":null,"around":null,"weather":null,"today":false,
       "tz":"America/Chicago","paused":false,"collected":[],"notes_total":1,"next":"a1",
       "notes":[{"id":"n-1","date":"2026-11-04","text":"Hi","revision":"r1","written_at":"2026-11-04T08:15:00Z","files":0}]}
      """
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    let day = try decoder.decode(DayDetail.self, from: Data(json.utf8))
    #expect(day.today == false)
    #expect(day.notes.map(\.text) == ["Hi"])
    #expect(day.next == "a1")
  }

  @Test func readsAWholeNote() async throws {
    StubProtocol.set("whole.test", .init(status: 200, body: Self.wholeNote))
    let note = try await client("whole.test").note(date: "2026-11-04", id: "w-1")
    #expect(note.isRich)
    #expect(note.plainWords == "A long day at Example #lake")
    #expect(note.sourceName == "on the web")
    #expect(!note.hasEmail)
    #expect(note.place?.label == "Lake Harriet, Minneapolis")
    #expect(note.media?.map(\.n) == [1, 3])
    #expect(note.media?.first?.thumb?.url == "https://files.test/t1")
    #expect(note.media?.last?.transcript == "Some words")
    #expect(note.parts?.last == .other)
  }

  /// What the app reads back today, from a server before 1.14.0, still reads.
  @Test func readsANoteFromBeforeTheWholeNote() async throws {
    StubProtocol.set("old.test", .init(status: 200, body: #"{"id":"t-1","date":"2026-10-28","text":"x","revision":"r","written_at":null,"files":0}"#))
    let note = try await client("old.test").note(date: "2026-10-28", id: "t-1")
    #expect(note.plainWords == "x")
    #expect(note.hasEmail)
  }

  @Test func asksForNotesAsTheGuideSays() async throws {
    StubProtocol.set("list.test", .init(status: 200, body: #"{"from":"2026-11-04","to":"2026-11-04","items":[\#(Self.wholeNote)],"next":"abc"}"#))
    let page = try await client("list.test").notes(from: "2026-11-04", to: "2026-11-04", after: "a:b#c", mine: true, urls: true)
    #expect(page.next == "abc")
    #expect(page.items.count == 1)
    let url = try #require(StubProtocol.requests("list.test").first?.url)
    let query = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") })
    #expect(url.path == "/v1/notes")
    #expect(query == ["from": "2026-11-04", "to": "2026-11-04", "after": "a:b#c", "limit": "100", "mine": "true", "include": "urls"])
  }

  @Test func asksForAFreshAddress() async throws {
    StubProtocol.set("file.test", .init(status: 200, body: #"{"url":"https://files.test/9","type":"image/jpeg","expires_in":600}"#))
    let address = try await client("file.test").fileAddress(date: "2026-11-04", id: "w-1", n: 3, thumb: true)
    #expect(address.url == "https://files.test/9")
    let url = try #require(StubProtocol.requests("file.test").first?.url)
    #expect(url.path == "/v1/notes/2026-11-04/w-1/media/3")
    #expect(url.query == "size=thumb")
  }

  @Test func namesAFileForItsPreview() {
    func entry(_ name: String?, _ type: String) -> NoteFileEntry {
      NoteFileEntry(n: 1, kind: "file", type: type, name: name, size: 1, thumb: nil)
    }
    #expect(entry("dock.jpg", "image/jpeg").previewName == "dock.jpg")
    #expect(entry("../../etc/passwd.pdf", "application/pdf").previewName == "-..-etc-passwd.pdf")
    #expect(entry(nil, "application/pdf").previewName == "file.pdf")
    #expect(entry("  ", "image/jpeg").previewName.hasPrefix("file."))
    #expect(entry("memo", "application/pdf").previewName == "memo.pdf")
  }

  // MARK: The switch

  private func me(account: String? = "acct_1", scopes: [String]) -> Me {
    Me(today: "2026-11-05", version: "4.5.144", tz: "America/Chicago", sendTime: "06:30", wroteToday: false, streak: 1,
       pausedUntil: nil, status: "active", showBadges: true, days: [],
       token: TokenInfo(name: "Changelog 2", scopes: scopes, expiresAt: nil, id: "t2"), apiVersion: "1.17.2", account: account)
  }

  private let old = "rn_old", new = "rn_new"
  private let reading = ["notes:write", "media:write", "notes:all", "upcoming", "activity"]

  private final class Ended: @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [String] = []
    func add(_ token: String) { lock.withLock { tokens.append(token) } }
    var all: [String] { lock.withLock { tokens } }
  }

  private func adopt(store: any TokenStore, ended: Ended, answer: Result<Me, APIError>) async -> Result<Me, TokenSwitch.Refused> {
    await TokenSwitch.adopt(new, replacing: old, account: "acct_1", store: store,
                            me: { (_) async throws(APIError) -> Me in try answer.get() },
                            revoke: { ended.add($0) })
  }

  @Test func aReadingTokenOfTheSameAccountIsKept() async throws {
    let store = MemoryTokenStore(old), ended = Ended()
    let answer = await adopt(store: store, ended: ended, answer: .success(me(scopes: reading)))
    #expect(try answer.get().token.readsAll)
    #expect(store.read() == new)
    // The old one is the caller's to end, once it has moved over.
    #expect(ended.all.isEmpty)
  }

  @Test func anotherAccountNeverTakesThePhone() async throws {
    let store = MemoryTokenStore(old), ended = Ended()
    let answer = await adopt(store: store, ended: ended, answer: .success(me(account: "acct_2", scopes: reading)))
    guard case .failure(let refused) = answer else { Issue.record("expected a refusal"); return }
    #expect(refused.message.contains("different"))
    #expect(store.read() == old)
    #expect(ended.all == [new])
  }

  @Test func aTokenWithReadingUntickedChangesNothing() async throws {
    let store = MemoryTokenStore(old), ended = Ended()
    let answer = await adopt(store: store, ended: ended, answer: .success(me(scopes: ["notes:write", "activity"])))
    guard case .failure(let refused) = answer else { Issue.record("expected a refusal"); return }
    #expect(refused.message.contains("Read all your notes"))
    #expect(store.read() == old)
    #expect(ended.all == [new])
  }

  @Test func readingBesideAddingStillWillDo() {
    #expect(TokenSwitch.refusal(of: me(scopes: ["notes:write", "notes:read"]), account: "acct_1") == nil)
    #expect(TokenSwitch.refusal(of: me(scopes: ["notes:read"]), account: "acct_1") != nil)
  }

  @Test func noAnswerChangesNothing() async throws {
    let store = MemoryTokenStore(old), ended = Ended()
    let answer = await adopt(store: store, ended: ended, answer: .failure(APIError(status: 0, code: "network", message: "Offline")))
    guard case .failure(let refused) = answer else { Issue.record("expected a refusal"); return }
    #expect(refused.message == "Offline")
    #expect(store.read() == old)
    #expect(ended.all == [new])
  }

  /// The Keychain clears before it adds, so a failure there puts the old back.
  private final class FailingStore: TokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var token: String?
    let refuse: String
    init(_ token: String, refuse: String) { self.token = token; self.refuse = refuse }
    func read() -> String? { lock.withLock { token } }
    func write(_ new: String) throws {
      try lock.withLock {
        token = nil
        if new == refuse { throw KeychainError(status: -1) }
        token = new
      }
    }
    func clear() { lock.withLock { token = nil } }
  }

  @Test func aKeychainThatFailsPutsTheOldTokenBack() async throws {
    let store = FailingStore(old, refuse: new), ended = Ended()
    let answer = await adopt(store: store, ended: ended, answer: .success(me(scopes: reading)))
    guard case .failure(let refused) = answer else { Issue.record("expected a refusal"); return }
    #expect(refused.message.contains("couldn't be kept"))
    #expect(store.read() == old)
    #expect(ended.all == [new])
  }
}
