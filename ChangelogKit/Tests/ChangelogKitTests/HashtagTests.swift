import Testing
@testable import ChangelogKit

@Suite struct HashtagTests {
  @Test(arguments: [
    ("Ran the #river-loop today", ["river-loop"]),
    ("#Maine2016 and #maine2016", ["maine2016"]),
    ("Café #Crème-Brûlée", ["creme-brulee"]),
    ("a#b c&#d /#e =#f", []),
    ("#2026 is not a tag, #y2026 is", ["y2026"]),
    ("##double and #trailing-", ["trailing"]),
  ])
  func findsTagsAsTheServerDoes(text: String, tags: [String]) {
    #expect(Hashtags.found(in: text) == tags)
  }

  /// Letters in any script make a tag, as Release Notes reads them since
  /// API 1.7.0: each expectation is what its `found` returns for the text.
  @Test(arguments: [
    ("Back in #東京 and #Москва", ["東京", "москва"]),
    ("#שלום from #Αθήνα", ["שלום", "αθήνα"]),
    ("#नमस्ते", ["नमस्ते"]),
    ("#東京-大阪 trip", ["東京-大阪"]),
    ("#東京2016 and #Ελλάδα2016", ["東京2016", "ελλάδα2016"]),
    ("#Café stays #cafe", ["cafe"]),
    ("a#東京 and 東#京", []),
    ("#2026 and #🎉", []),
  ])
  func findsTagsInAnyScript(text: String, tags: [String]) {
    #expect(Hashtags.found(in: text) == tags)
  }

  @Test func spellsWhatWasTyped() throws {
    #expect(try Hashtags.spelling("#Maine 2016").get() == Tag(key: "maine-2016", name: "Maine 2016"))
    #expect(try Hashtags.spelling("2016").get().key == "2016")
    #expect(Hashtags.spelling(String(repeating: "a", count: 51)) == .failure(.long))
    #expect(try Hashtags.spelling(String(repeating: "a", count: 50)).get().name.count == 50)
    #expect(try Hashtags.spelling("#Москва").get() == Tag(key: "москва", name: "Москва"))
    #expect(try Hashtags.spelling("#🎉").get().key == "🎉")
    #expect(Hashtags.spelling("#") == .failure(.empty))
    #expect(Hashtags.spelling("Road, Trip") == .failure(.comma))
  }

  @Test func addsToAField() throws {
    let one = try Hashtags.adding("Road Trip", to: []).get()
    #expect(one.tags == [Tag(key: "road-trip", name: "Road Trip")])
    #expect(one.added == Tag(key: "road-trip", name: "Road Trip"))
    // The same tag by another spelling adds nothing.
    let again = try Hashtags.adding("road trip", to: one.tags).get()
    #expect(again.tags == one.tags)
    #expect(again.added == nil)
    let full = (1...20).map { Tag(key: "t\($0)", name: "t\($0)") }
    #expect(Hashtags.adding("one more", to: full).map(\.tags) == .failure(.many))
    #expect(try Hashtags.adding("t3", to: full).get().added == nil)
  }

  @Test func aNoteHasItsFieldTagsThenItsWords() {
    let lake = Tag(key: "lake", name: "Lake")
    let trip = Tag(key: "road-trip", name: "Road Trip")
    #expect(Hashtags.chips("At the #lake", field: [trip]) == [trip, Tag(key: "lake", name: "lake")])
    #expect(Hashtags.chips("At the #lake", field: [lake]) == [lake])
    #expect(Hashtags.fieldOnly("At the #lake", tags: [trip, lake]) == [trip])
    #expect(Hashtags.line([trip, lake]) == "Road Trip, Lake")
    #expect(Hashtags.named(["road-trip", "lake"], ["Road Trip"]) == [trip, Tag(key: "lake", name: "lake")])
    #expect(Hashtags.named(nil, nil).isEmpty)
  }

  @Test func findsAKeyInWords() {
    #expect(Hashtags.contains("москва", in: "Snow in #Москва"))
    #expect(Hashtags.contains("house", in: "Fixed the #House faucet"))
    #expect(!Hashtags.contains("house", in: "Fixed the house faucet"))
  }

  /// As `removingTag` in Release Notes' `packages/domain/tags.ts`: the space
  /// before a tag goes with it, or for a tag leading the text, the one after.
  @Test(arguments: [
    ("#fixed the bug", "the bug"),
    ("#fixed", ""),
    ("#fixed ", ""),
    ("Fixed the bug #fixed", "Fixed the bug"),
    ("the #fixed bug", "the bug"),
    ("#fixed the bug #fixed", "the bug"),
    ("#fixed #fixed", ""),
    ("one\n#fixed two", "one\ntwo"),
    ("#fixed  two", " two"),
  ])
  func takesATagOffWithTheSpaceBesideIt(text: String, left: String) {
    #expect(Hashtags.removing("fixed", from: text) == left)
  }

  @Test func theRowIsPinnedThenRecentThenQuick() {
    let tags = Tags(pinned: ["house", "road-trip"], pinnedNames: ["House", "Road Trip"],
                    recent: [RecentTag(tag: "running", name: "Running", count: 6, lastUsed: nil),
                             RecentTag(tag: "road-trip", name: "road trip", count: 3, lastUsed: nil)],
                    windowDays: 30)
    #expect(TagRow.tags(tags, limit: 5).map(\.name) == ["House", "Road Trip", "Running", "added", "changed"])
    #expect(TagRow.tags(nil, limit: 12).map(\.key) == TagRow.quick)
    // An older server sends keys alone: each is its own name.
    let older = Tags(pinned: ["house"], recent: [RecentTag(tag: "work", count: 1, lastUsed: nil)], windowDays: 30)
    #expect(TagRow.tags(older, limit: 2).map(\.name) == ["house", "work"])
  }

  @Test func recognizesATokenInWhatWasPasted() {
    let token = "rn_" + String(repeating: "x", count: 42) + "Q"
    #expect(TokenFormat.looksValid(token))
    #expect(TokenFormat.extract("Your token: \(token)\n") == token)
    #expect(TokenFormat.extract("rn_short") == nil)
    #expect(!TokenFormat.looksValid("rn_" + String(repeating: "x", count: 44)))
  }
}
