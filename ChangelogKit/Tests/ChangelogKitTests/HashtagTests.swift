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

  @Test func normalizesWhatWasTyped() {
    #expect(Hashtags.normalize("#Maine 2016") == "maine-2016")
    #expect(Hashtags.normalize("2016") == nil)
    #expect(Hashtags.normalize(String(repeating: "a", count: 60))?.count == 50)
    #expect(Hashtags.normalize("#Москва") == "москва")
    #expect(Hashtags.normalize("東京") == "東京")
    #expect(Hashtags.normalize(String(repeating: "東", count: 60))?.unicodeScalars.count == 50)
    #expect(Hashtags.normalize("#🎉") == nil)
  }

  @Test func togglesATag() {
    #expect(Hashtags.toggling("house", in: "Fixed the faucet") == "Fixed the faucet #house")
    #expect(Hashtags.toggling("house", in: "Fixed the faucet #house") == "Fixed the faucet")
    #expect(Hashtags.toggling("house", in: "") == "#house ")
    #expect(Hashtags.adding("house", to: "Fixed the #House faucet") == "Fixed the #House faucet")
    #expect(Hashtags.toggling("東京", in: "Landed") == "Landed #東京")
    #expect(Hashtags.toggling("東京", in: "Landed #東京") == "Landed")
    #expect(Hashtags.contains("москва", in: "Snow in #Москва"))
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
    let tags = Tags(pinned: ["house", "work"],
                    recent: [RecentTag(tag: "running", count: 6, lastUsed: nil), RecentTag(tag: "work", count: 3, lastUsed: nil)],
                    windowDays: 30)
    #expect(TagRow.tags(tags, limit: 5) == ["house", "work", "running", "added", "changed"])
    #expect(TagRow.tags(nil, limit: 12) == TagRow.quick)
  }

  @Test func recognizesATokenInWhatWasPasted() {
    let token = "rn_" + String(repeating: "x", count: 42) + "Q"
    #expect(TokenFormat.looksValid(token))
    #expect(TokenFormat.extract("Your token: \(token)\n") == token)
    #expect(TokenFormat.extract("rn_short") == nil)
    #expect(!TokenFormat.looksValid("rn_" + String(repeating: "x", count: 44)))
  }
}
