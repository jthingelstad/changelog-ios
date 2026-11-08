import Foundation

/// A tag (Release Notes' `docs/TAGS.md`, API 1.21.0; Jamie, 2026-11-08:
/// "Approved: build first-class tags in Release Notes as proposed, with calls
/// 1 to 8 as recommended"). Its name is as it was typed and is shown ("Road
/// Trip", "🚗 Lake", "東京"); its key is what matches, so "Road Trip", "road
/// trip" and "#road-trip" are one tag, `road-trip`.
public struct Tag: Codable, Sendable, Hashable, Identifiable {
  public var key: String
  public var name: String

  public var id: String { key }

  public init(key: String, name: String) {
    self.key = key
    self.name = name
  }
}

/// Why a tags field won't take a name (call 4), as the server names it.
public enum TagRefusal: String, Sendable, Error, Equatable {
  case many, `break`, comma, long, empty

  /// What the field says, as the web's says it (`web/src/lib/tags.ts`).
  public var said: String {
    switch self {
    case .many: "That’s \(Hashtags.maxTags) tags, the most one can have. Take one off first."
    case .break: "A tag is one line."
    case .comma: "A tag has no commas. Add each tag on its own."
    case .long: "A tag is at most \(Hashtags.maxTag) characters."
    case .empty: "A tag needs a letter, a number or an emoji."
    }
  }
}

/// How Release Notes reads tags: a port of `packages/domain/tags.ts`; keep
/// them in step. `contracts/tag-vectors.json` there, copied beside this
/// package's tests, holds the cases both must agree on. Everything here works
/// in code points, as the server's `Array.from` does, never in Characters.
///
/// - A name's key: Latin letters alone keep the legacy slug (#Café is
///   `cafe`), other scripts alone their letters, lowercased (#東京 is `東京`,
///   #Москва is `москва`), and a name that mixes them or has emoji keeps
///   every part (`café-東京` is `cafe-東京`, "🚗 Road Trip" is `🚗-road-trip`).
/// - A hashtag in a note's words is a `#` not after a letter, digit or one of
///   `_#&/=`, then letters and digits joined by single hyphens, with a
///   letter: the words still make tags (call 1), and `#Road Trip` there is
///   the tag `road`.
/// - A tags field takes a name with spaces and emoji, at most 50 characters,
///   20 to an item, and refuses commas and line breaks (call 4).
public enum Hashtags {
  public static let maxTag = 50
  public static let maxTags = 20

  typealias Scalar = Unicode.Scalar

  // MARK: Characters, as the server's regular expressions class them

  /// Python's `isalnum`, which the server's tables are made from.
  static func alnum(_ s: Scalar) -> Bool {
    letter(s) || s.properties.numericType != nil
  }

  /// `\p{L}`.
  static func letter(_ s: Scalar) -> Bool {
    switch s.properties.generalCategory {
    case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: true
    default: false
    }
  }

  /// `[\p{L}\p{N}]`.
  static func word(_ s: Scalar) -> Bool {
    switch s.properties.generalCategory {
    case .decimalNumber, .letterNumber, .otherNumber: true
    default: letter(s)
    }
  }

  static func mark(_ s: Scalar?) -> Bool {
    guard let s else { return false }
    switch s.properties.generalCategory {
    case .nonspacingMark, .spacingMark, .enclosingMark: return true
    default: return false
    }
  }

  static func joiner(_ s: Scalar?) -> Bool { s == "\u{200C}" || s == "\u{200D}" }

  static func inWord(_ s: Scalar?) -> Bool {
    guard let s else { return false }
    return alnum(s) || mark(s)
  }

  /// ICU's own Unicode properties, which Swift's don't reach: the script, and
  /// emoji as the server's `EMOJI` class has them.
  nonisolated(unsafe) private static let latinPattern = try! NSRegularExpression(pattern: "^\\p{Script=Latin}$")
  nonisolated(unsafe) private static let emojiPattern = try! NSRegularExpression(
    pattern: "^[\\p{Extended_Pictographic}\\p{Emoji_Modifier}\\p{Regional_Indicator}\\u20e3\\x{e0020}-\\x{e007f}]$")

  private static func matches(_ pattern: NSRegularExpression, _ s: Scalar) -> Bool {
    let one = String(s)
    return pattern.firstMatch(in: one, range: NSRange(location: 0, length: one.utf16.count)) != nil
  }

  static func latinScript(_ s: Scalar) -> Bool {
    if s.isASCII { return ("a"..."z").contains(s) || ("A"..."Z").contains(s) }
    return matches(latinPattern, s)
  }

  static func emoji(_ s: Scalar) -> Bool {
    if s.isASCII { return false }
    return matches(emojiPattern, s)
  }

  /// NFKD, then only what is ASCII, as stored slugs are made.
  static func asciiDecompose<S: Sequence>(_ scalars: S) -> String where S.Element == Scalar {
    var out = String.UnicodeScalarView()
    for s in scalars {
      if s.isASCII {
        out.append(s)
      } else {
        out.append(contentsOf: String(s).decomposedStringWithCompatibilityMapping.unicodeScalars.filter(\.isASCII))
      }
    }
    return String(out)
  }

  static func scalars(_ text: String) -> [Scalar] { Array(text.unicodeScalars) }

  static func string<C: Collection>(_ scalars: C) -> String where C.Element == Scalar {
    var out = String.UnicodeScalarView()
    out.append(contentsOf: scalars)
    return String(out)
  }

  /// Drops trailing hyphens and joiners.
  private static func trimmingTail(_ out: [Scalar]) -> String {
    var end = out.count
    while end > 0, out[end - 1] == "-" || joiner(out[end - 1]) { end -= 1 }
    return string(out[0..<end])
  }

  // MARK: Keys

  /// The legacy slug: ASCII letters and digits, lowercased, joined by single
  /// hyphens, at most 50.
  public static func slug(_ name: String) -> String {
    let ascii = asciiDecompose(name.unicodeScalars).lowercased()
    var out = ""
    var gap = false
    for s in ascii.unicodeScalars {
      if ("a"..."z").contains(s) || ("0"..."9").contains(s) {
        if gap && !out.isEmpty { out.append("-") }
        out.unicodeScalars.append(s)
        gap = false
      } else {
        gap = true
      }
    }
    if out.count > maxTag { out = String(out.prefix(maxTag)) }
    while out.hasSuffix("-") { out.removeLast() }
    return out
  }

  /// Has a letter, in any script.
  public static func valid(_ tag: String) -> Bool { tag.unicodeScalars.contains(where: letter) }

  /// Has an a-z letter: a tag the old slug makes.
  static func latin(_ tag: String) -> Bool { tag.unicodeScalars.contains { ("a"..."z").contains($0) } }

  /// Past one word from `at` (its first alphanumeric): letters, numbers and
  /// marks in any script, a joiner only inside, words joined by single
  /// hyphens.
  static func wordsFrom(_ chars: [Scalar], _ at: Int) -> Int {
    var end = at
    func char(_ i: Int) -> Scalar? { i < chars.count ? chars[i] : nil }
    func word() {
      end += 1
      while inWord(char(end)) || (joiner(char(end)) && inWord(char(end + 1))) { end += 1 }
    }
    word()
    while char(end) == "-", let next = char(end + 1), alnum(next) {
      end += 1
      word()
    }
    return end
  }

  /// A name's tag in any script: its words, lowercased (NFC), joined by
  /// hyphens, at most 50 code points, never cut inside a letter's marks.
  static func wide(_ name: String) -> String {
    let chars = scalars(name.lowercased().precomposedStringWithCanonicalMapping)
    func char(_ i: Int) -> Scalar? { i < chars.count ? chars[i] : nil }
    var words: [[Scalar]] = []
    var at = 0
    while at < chars.count {
      guard alnum(chars[at]) else {
        at += 1
        continue
      }
      var end = at + 1
      while inWord(char(end)) || (joiner(char(end)) && inWord(char(end + 1))) { end += 1 }
      words.append(Array(chars[at..<end]))
      at = end
    }
    let out = Array(words.joined(separator: ["-"]))
    var end = min(out.count, maxTag)
    while end > 0, end < out.count, mark(out[end]) || joiner(out[end - 1]) { end -= 1 }
    return trimmingTail(Array(out[0..<end]))
  }

  /// A name with emoji, or letters from Latin and another script: each part
  /// kept, Latin letters without their accents as the slug has them, the rest
  /// lowercased with their marks, emoji as they are, and anything else
  /// between words one hyphen.
  static func mixed(_ name: String) -> String {
    let chars = scalars(name.precomposedStringWithCanonicalMapping.lowercased())
      .filter { $0 != "\u{FE0E}" && $0 != "\u{FE0F}" }
    func char(_ i: Int) -> Scalar? { i < chars.count ? chars[i] : nil }
    func kept(_ s: Scalar?) -> Bool {
      guard let s else { return false }
      return word(s) || emoji(s) || mark(s)
    }
    var words: [[Scalar]] = []
    var current: [Scalar] = []
    var folded = false
    for (at, c) in chars.enumerated() {
      if word(c) {
        let ascii = asciiDecompose([c]).unicodeScalars
        let lettersOnly = !ascii.isEmpty && ascii.allSatisfy { ("a"..."z").contains($0) }
        let digit = ascii.count == 1 && ("0"..."9").contains(ascii.first!)
        if (latinScript(c) && lettersOnly) || digit {
          current.append(contentsOf: ascii)
          folded = true
        } else {
          current.append(c)
          folded = false
        }
      } else if mark(c) {
        // A mark stays with a letter kept as it is; an accent goes with its
        // folded letter, as the slug drops it.
        if !current.isEmpty && !folded { current.append(c) }
      } else if emoji(c) {
        current.append(c)
        folded = false
      } else if joiner(c) && !current.isEmpty && kept(char(at + 1)) {
        current.append(c)
      } else if !current.isEmpty {
        words.append(current)
        current = []
      }
    }
    if !current.isEmpty { words.append(current) }
    let out = Array(words.joined(separator: ["-"]))
    var end = min(out.count, maxTag)
    while end > 0, end < out.count, mark(out[end]) || joiner(out[end - 1]) || joiner(out[end]) { end -= 1 }
    return trimmingTail(Array(out[0..<end]))
  }

  /// A name's key: what matches, so "Road Trip" and "road-trip" are one tag.
  /// Latin letters alone keep the legacy slug, and other scripts alone their
  /// letters, so no key from before moves; a mix, or emoji, keeps each part.
  public static func key(_ name: String) -> String {
    let text = name.precomposedStringWithCanonicalMapping
    let letters = text.unicodeScalars.filter(letter)
    let latinOnly = letters.allSatisfy(latinScript)
    let noLatin = !letters.contains(where: latinScript)
    if !text.unicodeScalars.contains(where: emoji) {
      if latinOnly {
        let old = slug(text)
        if latin(old) { return old }
      } else if noLatin {
        return wide(text)
      }
    }
    return mixed(text)
  }

  /// A key as tags are matched by: already a key, at most 50 code points.
  public static func isKey(_ tag: String) -> Bool {
    !tag.isEmpty && tag.unicodeScalars.count <= maxTag && key(tag) == tag
  }

  // MARK: A tags field

  private static let lineBreaks: Set<Scalar> = ["\n", "\r", "\u{2028}", "\u{2029}", "\u{0085}"]
  private static let commas: Set<Scalar> = [",", "\u{FF0C}"]

  /// `[\s\p{Zs}᠎​⁠﻿]`, as the server runs them together.
  static func space(_ s: Scalar) -> Bool {
    switch s {
    case "\t", "\n", "\u{0B}", "\u{0C}", "\r", " ", "\u{A0}", "\u{1680}", "\u{2028}", "\u{2029}", "\u{202F}", "\u{205F}",
         "\u{3000}", "\u{FEFF}", "\u{180E}", "\u{200B}", "\u{2060}":
      return true
    default:
      return ("\u{2000}"..."\u{200A}").contains(s) || s.properties.generalCategory == .spaceSeparator
    }
  }

  /// A name as a tags field takes it: leading #s and the spaces around it
  /// gone, runs of spaces made one, composed (NFC). Commas, line breaks and
  /// other control characters are refused, never dropped, as is a name over
  /// 50 characters, or one with no letter, number or emoji.
  public static func spelling(_ raw: String) -> Result<Tag, TagRefusal> {
    let chars = scalars(raw.precomposedStringWithCanonicalMapping)
    if chars.contains(where: lineBreaks.contains) { return .failure(.break) }
    if chars.contains(where: commas.contains) { return .failure(.comma) }
    if chars.contains(where: { $0 != "\t" && $0.properties.generalCategory == .control }) { return .failure(.break) }
    var spaced: [Scalar] = []
    for s in chars {
      if space(s) {
        if spaced.last != " " { spaced.append(" ") }
      } else {
        spaced.append(s)
      }
    }
    var name = string(spaced).trimmingCharacters(in: [" "])
    while name.hasPrefix("#") { name.removeFirst() }
    name = name.trimmingCharacters(in: [" "])
    if name.unicodeScalars.count > maxTag { return .failure(.long) }
    let key = key(name)
    return key.isEmpty ? .failure(.empty) : .success(Tag(key: key, name: name))
  }

  /// A name typed into a tags field, added to `tags`: the list with it, and
  /// the tag added, or why not. A tag already there by any spelling leaves
  /// the list as it was, with nothing added.
  public static func adding(_ typed: String, to tags: [Tag]) -> Result<(tags: [Tag], added: Tag?), TagRefusal> {
    switch spelling(typed) {
    case .failure(let why): return .failure(why)
    case .success(let tag):
      if tags.contains(where: { $0.key == tag.key }) { return .success((tags, nil)) }
      if tags.count >= maxTags { return .failure(.many) }
      return .success((tags + [tag], tag))
    }
  }

  /// Lists of tags as one: each key once, its first name, at most 20.
  public static func merge(_ lists: [Tag]...) -> [Tag] {
    var out: [Tag] = []
    for list in lists {
      for tag in list where out.count < maxTags && !out.contains(where: { $0.key == tag.key }) { out.append(tag) }
    }
    return out
  }

  /// The tags an answer gives, its keys beside their names.
  public static func named(_ keys: [String]?, _ names: [String]?) -> [Tag] {
    let names = names ?? []
    return merge((keys ?? []).enumerated().map { i, key in
      Tag(key: key, name: i < names.count && !names[i].isEmpty ? names[i] : key)
    })
  }

  /// A note's chips: the tags from its field, then its #words, as the server
  /// keeps them.
  public static func chips(_ text: String, field: [Tag]) -> [Tag] { merge(field, textTags(text)) }

  /// The tags a note has that its words don't: the ones a field gave it.
  public static func fieldOnly(_ text: String, tags: [Tag]) -> [Tag] {
    let typed = Set(textTags(text).map(\.key))
    return tags.filter { !typed.contains($0.key) }
  }

  /// Names as one line, "Road Trip, lake".
  public static func line(_ tags: [Tag]) -> String { tags.map(\.name).joined(separator: ", ") }

  // MARK: Hashtags in a note's words

  struct Span: Equatable { var start: Int; var end: Int; var tag: String }

  /// The hashtags in a text, by code point.
  static func spans(_ text: String) -> [Span] {
    let chars = scalars(text)
    func char(_ i: Int) -> Scalar? { i >= 0 && i < chars.count ? chars[i] : nil }
    var out: [Span] = []
    var start = 0
    while start < chars.count {
      defer { start += 1 }
      guard chars[start] == "#" else { continue }
      if let before = char(start - 1), alnum(before) || "_#&/=".unicodeScalars.contains(before) { continue }
      var end = start + 1
      guard let first = char(end), alnum(first) else { continue }
      while end < chars.count, alnum(chars[end]) { end += 1 }
      while char(end) == "-", let next = char(end + 1), alnum(next) {
        end += 1
        while end < chars.count, alnum(chars[end]) { end += 1 }
      }
      let typed = string(chars[(start + 1)..<end])
      if latin(slug(typed)) {
        // Its key: the legacy slug, unless it mixes in another script.
        out.append(Span(start: start, end: end, tag: key(typed)))
        start = end - 1
        continue
      }
      // No a-z letter: read on through marks and joiners, and if the whole
      // hashtag still has none, its own letters are the tag.
      let far = wordsFrom(chars, start + 1)
      let body = string(chars[(start + 1)..<far])
      let own = wide(body)
      if !latin(slug(body)), valid(own), key(own) == own {
        out.append(Span(start: start, end: far, tag: own))
        start = far - 1
      } else {
        start = end - 1
      }
    }
    return out
  }

  /// The hashtags in a text as tags, each named as typed, without its #.
  public static func textTags(_ text: String) -> [Tag] {
    let chars = scalars(text)
    var out: [Tag] = []
    for span in spans(text) {
      if out.count >= maxTags { break }
      if !out.contains(where: { $0.key == span.tag }) {
        out.append(Tag(key: span.tag, name: string(chars[(span.start + 1)..<span.end])))
      }
    }
    return out
  }

  /// The tags in a text, in order, each once.
  public static func found(in text: String) -> [String] { textTags(text).map(\.key) }

  public static func contains(_ key: String, in text: String) -> Bool {
    spans(text).contains { $0.tag == key }
  }

  /// Takes every `#tag` for this key out with the space beside it: the one
  /// before, or for a tag with none before (one leading the text), the one
  /// after, as `removingTag` does. Removing a #word's chip does this (call 1).
  public static func removing(_ key: String, from text: String) -> String {
    var chars = scalars(text)
    for span in spans(text).reversed() where span.tag == key {
      let before = span.start > 0 && chars[span.start - 1] == " "
      let after = !before && span.end < chars.count && chars[span.end] == " "
      chars.removeSubrange((before ? span.start - 1 : span.start)..<(after ? span.end + 1 : span.end))
    }
    return string(chars)
  }
}

/// The row of one-tap tags under the box: pinned first, then the most used
/// recently, then Keep a Changelog's words if room is left, each by its name.
public enum TagRow {
  public static let quick = ["added", "changed", "fixed", "removed"]

  public static func tags(_ tags: Tags?, limit: Int = 12, quick: [String] = TagRow.quick) -> [Tag] {
    let pinned = tags?.pinnedTags ?? []
    let recent = (tags?.recent ?? []).map { Tag(key: $0.tag, name: $0.name ?? $0.tag) }
    var row: [Tag] = []
    for tag in pinned + recent + quick.map({ Tag(key: $0, name: $0) }) where !row.contains(where: { $0.key == tag.key }) {
      row.append(tag)
    }
    return Array(row.prefix(max(limit, pinned.count)))
  }
}
