import Foundation

/// Hashtags live in the note's text, as Release Notes reads them
/// (`packages/domain/tags.ts`): a `#` not after a letter, digit or one of
/// `_#&/=`, then letters and digits joined by single hyphens, at most 50
/// characters, with at least one letter. One with an a-z letter is the old
/// slug, lowercased and folded to ASCII (#Café is cafe), so no tag moves;
/// one without is its own letters in any script, lowercased (#東京 is 東京,
/// #Москва is москва; Release Notes API 1.7.0, 2026-10-30). The server stays
/// the authority; this is for the tag row's on and off and the pinned tags.
public enum Hashtags {
  public static let maxTag = 50

  public static func slug(_ name: String) -> String {
    let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil).lowercased()
    var out = ""
    var gap = false
    for scalar in folded.unicodeScalars {
      if ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) {
        if gap && !out.isEmpty { out.append("-") }
        out.unicodeScalars.append(scalar)
        gap = false
      } else {
        gap = true
      }
    }
    if out.count > maxTag { out = String(out.prefix(maxTag)) }
    while out.hasSuffix("-") { out.removeLast() }
    return out
  }

  /// Has a letter, in any script: what a tag needs.
  public static func valid(_ tag: String) -> Bool {
    tag.contains { $0.isLetter }
  }

  /// Has an a-z letter: a tag the old slug makes, kept exactly as it was.
  static func latin(_ tag: String) -> Bool {
    tag.unicodeScalars.contains { ("a"..."z").contains($0) }
  }

  static func isWord(_ c: Character) -> Bool { c.isLetter || c.isNumber }

  /// A name's tag in any script, as the server's `wide`: its words,
  /// lowercased (NFC), joined by hyphens, at most 50 code points and never
  /// cut inside a letter (a Character keeps its marks and joiners).
  static func wide(_ name: String) -> String {
    var words: [String] = []
    var word = ""
    for c in name.lowercased().precomposedStringWithCanonicalMapping {
      if isWord(c) {
        word.append(c)
      } else if !word.isEmpty {
        words.append(word)
        word = ""
      }
    }
    if !word.isEmpty { words.append(word) }
    var out = ""
    var count = 0
    for c in words.joined(separator: "-") {
      count += c.unicodeScalars.count
      if count > maxTag { break }
      out.append(c)
    }
    while let last = out.unicodeScalars.last, ["-", "\u{200C}", "\u{200D}"].contains(last) {
      out.unicodeScalars.removeLast()
    }
    return out
  }

  /// A name as a tag, as the server's `tagName`: the old slug when it has
  /// a-z letters, otherwise its letters in any script.
  public static func tagName(_ name: String) -> String {
    let old = slug(name)
    return latin(old) ? old : wide(name)
  }

  /// A tag as the owner typed it ("#Maine 2016", "Москва"), or nil if it has
  /// no letter.
  public static func normalize(_ raw: String) -> String? {
    let tag = tagName(raw.hasPrefix("#") ? String(raw.dropFirst()) : raw)
    return valid(tag) ? tag : nil
  }

  /// The tags in a text, in order, each once.
  public static func found(in text: String) -> [String] {
    var seen = Set<String>()
    return spans(text).map(\.tag).filter { seen.insert($0).inserted }
  }

  public static func contains(_ tag: String, in text: String) -> Bool {
    spans(text).contains { $0.tag == tag }
  }

  /// Adds `#tag` at the end, on the same line, unless the text has it.
  public static func adding(_ tag: String, to text: String) -> String {
    guard valid(tag), !contains(tag, in: text) else { return text }
    let trimmed = text.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
    return trimmed.isEmpty ? "#\(tag) " : "\(trimmed) #\(tag)"
  }

  /// Takes every `#tag` for this tag out with the space beside it: the one
  /// before, or for a tag with none before (one leading the text), the one
  /// after, as `removingTag` does.
  public static func removing(_ tag: String, from text: String) -> String {
    var chars = Array(text)
    for span in spans(text).reversed() where span.tag == tag {
      let before = span.start > 0 && chars[span.start - 1] == " "
      let after = !before && span.end < chars.count && chars[span.end] == " "
      chars.removeSubrange((before ? span.start - 1 : span.start)..<(after ? span.end + 1 : span.end))
    }
    return String(chars)
  }

  /// The tag row's tap: on if it's off, off if it's on.
  public static func toggling(_ tag: String, in text: String) -> String {
    contains(tag, in: text) ? removing(tag, from: text) : adding(tag, to: text)
  }

  struct Span: Equatable { var start: Int; var end: Int; var tag: String }

  static func spans(_ text: String) -> [Span] {
    let chars = Array(text)
    var out: [Span] = []
    var start = 0
    let word = isWord
    while start < chars.count {
      defer { start += 1 }
      guard chars[start] == "#" else { continue }
      if start > 0, word(chars[start - 1]) || "_#&/=".contains(chars[start - 1]) { continue }
      var end = start + 1
      guard end < chars.count, word(chars[end]) else { continue }
      while end < chars.count, word(chars[end]) { end += 1 }
      while end + 1 < chars.count, chars[end] == "-", word(chars[end + 1]) {
        end += 1
        while end < chars.count, word(chars[end]) { end += 1 }
      }
      let body = String(chars[(start + 1)..<end])
      let old = slug(body)
      if latin(old) {
        out.append(Span(start: start, end: end, tag: old))
      } else {
        // No a-z letter: its own letters are the tag, if it has one.
        let own = wide(body)
        if valid(own), tagName(own) == own { out.append(Span(start: start, end: end, tag: own)) }
      }
      start = end - 1
    }
    return out
  }
}

/// The row of one-tap tags above the keyboard: pinned first, then the most
/// used recently, then Keep a Changelog's words if room is left.
public enum TagRow {
  public static let quick = ["added", "changed", "fixed", "removed"]

  public static func tags(_ tags: Tags?, limit: Int = 12, quick: [String] = TagRow.quick) -> [String] {
    var seen = Set<String>()
    let pinned = tags?.pinned ?? []
    let recent = tags?.recent.map(\.tag) ?? []
    let row = (pinned + recent + quick).filter { seen.insert($0).inserted }
    return Array(row.prefix(max(limit, pinned.count)))
  }
}
