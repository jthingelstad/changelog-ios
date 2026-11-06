import Testing
@testable import ChangelogKit

/// The same cases as Release Notes' `tests-node/domain/rich.test.ts`, written
/// the same way: a block's lines as text, marks as <b> and <i>, atoms as [x].
struct RichTests {
  private func shown(_ line: Rich.Line) -> String {
    line.map { piece in
      let (words, marks): (String, Rich.Marks)
      switch piece {
      case .text(let text, let m): (words, marks) = (text, m)
      case .atom(let part, let m): (words, marks) = ("[\(Rich.text(of: part))]", m)
      }
      var out = words
      if marks.em { out = "<i>\(out)</i>" }
      if marks.strong { out = "<b>\(out)</b>" }
      return out
    }.joined()
  }

  private func shown(_ blocks: [Rich.Block]) -> [[String]] {
    blocks.map { block in
      switch block {
      case .para(let lines): ["para"] + lines.map(shown)
      case .quote(let inner): ["quote"] + shown(inner).flatMap { $0 }
      case .bullets(let items): ["bullets"] + items.map { $0.map(shown).joined(separator: " / ") }
      case .numbers(let start, let items): ["numbers", String(start)] + items.map { $0.map(shown).joined(separator: " / ") }
      }
    }
  }

  private func read(_ text: String) -> [[String]] { shown(Rich.blocks([.text(text)])) }

  @Test func boldAndItalicPairAroundWords() {
    #expect(read("A **long** day at the *lake* and _the dock_, ***both***.") == [
      ["para", "A <b>long</b> day at the <i>lake</i> and <i>the dock</i>, <b><i>both</i></b>."],
    ])
  }

  @Test(arguments: [
    "A 5* hotel, 2*3*4 = 24 and snake_case_name.",
    "An ** open bold and a * lone star.",
    "**not closed",
    "a*b*c and x_y_z",
    "*not closed either and _nor this",
  ])
  func marksThatDontPairStay(_ text: String) {
    #expect(read(text) == [["para", text]])
  }

  @Test func pairsStayWithinALine() {
    #expect(read("*one\ntwo*") == [["para", "*one", "two*"]])
  }

  @Test func listsAndQuotesAreLinesThatStartWithTheirMarks() {
    #expect(read("Packed:\n- towels\n* a **dry** bag\n  that floats\n\n3. third\n4) fourth\n\n> cold water\n> and *clear*\n\nAfter.") == [
      ["para", "Packed:"],
      ["bullets", "towels", "a <b>dry</b> bag / that floats"],
      ["numbers", "3", "third", "fourth"],
      ["quote", "para", "cold water", "and <i>clear</i>"],
      ["para", "After."],
    ])
    #expect(read("-\n---\n-- two dashes\n—one") == [["para", "-", "---", "-- two dashes", "—one"]])
    #expect(read("1999. A good year.") == [["para", "1999. A good year."]])
  }

  @Test func anIndentedLineGoesOnWithItsItemEvenFromALink() {
    let link = NotePart.link(url: "https://example.com", label: "Example", site: nil)
    #expect(shown(Rich.blocks([.text("- first\n  "), link, .text(" and words")])) == [["bullets", "first / [Example] and words"]])
  }

  @Test func quotesNestThreeDeep() {
    #expect(read("> > > > deep") == [["quote", "quote", "quote", "para", "> deep"]])
  }

  @Test func aBackslashKeepsAMarkAsTyped() {
    #expect(read("\\*not italic\\* and \\- this") == [["para", "*not italic* and - this"]])
  }

  @Test func linksAndTagsAreNeverReadForMarks() {
    let parts: [NotePart] = [
      .text("See "), .link(url: "https://example.com/a_b_c", label: "a_b_c", site: nil), .text("_ and **"),
      .link(url: "https://example.com/x", label: "x", site: nil), .text("** "), .tag(tag: "lake", text: "#lake"), .text("."),
    ]
    #expect(shown(Rich.blocks(parts)) == [["para", "See [a_b_c]_ and <b>[x]</b> [#lake]."]])
  }

  @Test func wordsReadWithoutTheMarks() {
    #expect(Rich.words(Rich.blocks([.text("A **long** day.\n\n- one\n- *two*\n\n> quoted")])) == "A long day.\n\none\ntwo\n\nquoted")
  }

  @Test func keepsAnEmojiAndAnAccentWhole() {
    #expect(read("**🧑🏽‍🚀 cafe\u{301}** \r\nnext") == [["para", "<b>🧑🏽‍🚀 cafe\u{301}</b> ", "next"]])
  }
}
