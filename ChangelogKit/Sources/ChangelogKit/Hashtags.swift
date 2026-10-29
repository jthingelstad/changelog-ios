import Foundation

/// Hashtags live in the note's text, as Release Notes reads them
/// (`packages/domain/tags.ts`): a `#` not after a letter, digit or one of
/// `_#&/=`, then letters and digits joined by single hyphens, lowercased and
/// folded to ASCII, at most 50 characters, with at least one letter. The
/// server stays the authority; this is for the tag row's on and off.
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

  public static func valid(_ tag: String) -> Bool {
    tag.unicodeScalars.contains { ("a"..."z").contains($0) }
  }

  /// A tag as the owner typed it ("#Maine 2016"), or nil if it has no letter.
  public static func normalize(_ raw: String) -> String? {
    let tag = slug(raw.hasPrefix("#") ? String(raw.dropFirst()) : raw)
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

  /// Takes every `#tag` for this tag out, tidying the space it leaves.
  public static func removing(_ tag: String, from text: String) -> String {
    var chars = Array(text)
    for span in spans(text).reversed() where span.tag == tag {
      var start = span.start
      if start > 0, chars[start - 1] == " " { start -= 1 }
      chars.removeSubrange(start..<span.end)
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
    func word(_ c: Character) -> Bool { c.isLetter || c.isNumber }
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
      let tag = slug(String(chars[(start + 1)..<end]))
      if valid(tag) { out.append(Span(start: start, end: end, tag: tag)) }
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
