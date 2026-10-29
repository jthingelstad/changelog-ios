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

  @Test func normalizesWhatWasTyped() {
    #expect(Hashtags.normalize("#Maine 2016") == "maine-2016")
    #expect(Hashtags.normalize("2016") == nil)
    #expect(Hashtags.normalize(String(repeating: "a", count: 60))?.count == 50)
  }

  @Test func togglesATag() {
    #expect(Hashtags.toggling("house", in: "Fixed the faucet") == "Fixed the faucet #house")
    #expect(Hashtags.toggling("house", in: "Fixed the faucet #house") == "Fixed the faucet")
    #expect(Hashtags.toggling("house", in: "") == "#house ")
    #expect(Hashtags.adding("house", to: "Fixed the #House faucet") == "Fixed the #House faucet")
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
