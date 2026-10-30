import Testing
@testable import ChangelogKit

@Suite struct SharedWordsTests {
  /// Notes and a Safari selection give the passage as the item's text and
  /// again as a plain-text attachment: it is filed once.
  @Test func aPassageGivenTwiceIsTakenOnce() {
    let passage = "Moved the fern to the north window.\nIt likes it there."
    #expect(SharedWords.joined([passage, passage + "\n"]) == passage)
    #expect(SharedWords.joined([passage, "Moved the fern to the north window. It likes  it there."]) == passage)
  }

  @Test func differentWordsAllComeInOrder() {
    #expect(SharedWords.joined(["Worth a read", "https://example.com/fern-care", "  "]) == "Worth a read\nhttps://example.com/fern-care")
    #expect(SharedWords.joined([]) == "")
  }
}
