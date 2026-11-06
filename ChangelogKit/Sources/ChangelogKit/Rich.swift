import Foundation

/// A rich note's words as blocks: a port of Release Notes'
/// `packages/domain/rich.ts`. Keep them in step. Only a note stamped
/// `markup: "rich"` is read this way; every other note is its words as typed.
///
/// The subset: **bold** (or __bold__), *italic* (or _italic_), lines starting
/// "- ", "* " or "• " as a bulleted list, "1. " or "1) " as a numbered one,
/// "> " as a quote, a blank line between paragraphs and a newline as a line
/// break. Links and hashtags come in as atoms: markup never splits one, and
/// one can sit inside bold or italic. Emphasis pairs strictly, within a line,
/// so "5* hotel", "2*3*4" and snake_case stay as typed.
public enum Rich {
  public struct Marks: Equatable, Sendable {
    public var strong = false
    public var em = false

    public init(strong: Bool = false, em: Bool = false) {
      self.strong = strong
      self.em = em
    }
  }

  public enum Inline: Equatable, Sendable {
    case text(String, Marks)
    case atom(NotePart, Marks)
  }

  public typealias Line = [Inline]

  public indirect enum Block: Equatable, Sendable {
    case para([Line])
    case bullets([[Line]])
    case numbers(start: Int, [[Line]])
    case quote([Block])
  }

  /// Quotes nest this deep; a deeper > stays as typed.
  private static let quoteDepth = 3

  /// The blocks a rich note's `parts` make.
  public static func blocks(_ parts: [NotePart]) -> [Block] {
    parse(lines(of: parts), depth: 0)
  }

  /// The words without the marks, a line a line, a blank line between blocks:
  /// what a line in a list shows.
  public static func words(_ written: [Block]) -> String {
    written.map { block in
      switch block {
      case .para(let lines): lines.map(words).joined(separator: "\n")
      case .quote(let inner): words(inner)
      case .bullets(let items), .numbers(_, let items):
        items.map { $0.map(words).joined(separator: "\n") }.joined(separator: "\n")
      }
    }.joined(separator: "\n\n")
  }

  private static func words(_ line: Line) -> String {
    line.map { piece in
      switch piece {
      case .text(let text, _): text
      case .atom(let part, _): Self.text(of: part)
      }
    }.joined()
  }

  /// An atom as it reads in words.
  public static func text(of part: NotePart) -> String {
    switch part {
    case .text(let words): words
    case .link(_, let label, _): label
    case .tag(_, let text): text
    case .other: ""
    }
  }

  // MARK: Lines

  /// One code point, or one atom. `literal`: a backslash kept it as typed.
  private enum Unit {
    case char(Unicode.Scalar, literal: Bool = false)
    case atom(NotePart)

    var scalar: Unicode.Scalar? {
      if case .char(let c, _) = self { c } else { nil }
    }
    /// A mark's candidate: a character no backslash kept.
    var bare: Unicode.Scalar? {
      if case .char(let c, false) = self { c } else { nil }
    }
  }

  private static func lines(of parts: [NotePart]) -> [[Unit]] {
    var out: [[Unit]] = [[]]
    for part in parts {
      guard case .text(let words) = part else {
        if part != .other { out[out.count - 1].append(.atom(part)) }
        continue
      }
      let scalars = Array(words.unicodeScalars)
      var i = 0
      while i < scalars.count {
        let c = scalars[i]
        if c == "\r" {
          // \r\n and \r alike end the line.
          if i + 1 < scalars.count, scalars[i + 1] == "\n" { i += 1 }
          out.append([])
        } else if c == "\n" {
          out.append([])
        } else {
          out[out.count - 1].append(.char(c))
        }
        i += 1
      }
    }
    return out
  }

  /// The line's characters up to its first atom: where its marker would be.
  private static func lead(_ line: [Unit]) -> [Unicode.Scalar] {
    var out: [Unicode.Scalar] = []
    for unit in line {
      guard let c = unit.scalar else { break }
      out.append(c)
    }
    return out
  }

  private static func isSpace(_ c: Unicode.Scalar) -> Bool {
    switch c.value {
    case 0x09...0x0D, 0x1C...0x20, 0x85, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000: true
    default: false
    }
  }

  private static func isBlank(_ line: [Unit]) -> Bool {
    line.allSatisfy { $0.scalar.map(isSpace) ?? false }
  }

  private static func isTab(_ c: Unicode.Scalar) -> Bool { c == " " || c == "\t" }

  /// How many characters a quote's "> " takes: up to three spaces, the >, and
  /// one space more if there is one.
  private static func quoteMarker(_ head: [Unicode.Scalar]) -> Int? {
    var i = 0
    while i < head.count, i < 3, head[i] == " " { i += 1 }
    guard i < head.count, head[i] == ">" else { return nil }
    i += 1
    if i < head.count, head[i] == " " { i += 1 }
    return i
  }

  private enum ItemKind { case bullets, numbers }

  private static func item(_ line: [Unit]) -> (kind: ItemKind, n: Int, rest: [Unit])? {
    let head = lead(line)
    var i = 0
    while i < head.count, isTab(head[i]) { i += 1 }
    var kind = ItemKind.bullets
    var n = 1
    if i < head.count, head[i] == "-" || head[i] == "*" || head[i] == "•" {
      i += 1
    } else {
      let start = i
      while i < head.count, i - start < 3, ("0"..."9").contains(head[i]) {
        i += 1
      }
      guard i > start, i < head.count, head[i] == "." || head[i] == ")" else { return nil }
      n = Int(String(String.UnicodeScalarView(head[start..<i]))) ?? 1
      kind = .numbers
      i += 1
    }
    let spaces = i
    while i < head.count, isTab(head[i]) { i += 1 }
    guard i > spaces else { return nil }
    let rest = Array(line[i...])
    return isBlank(rest) ? nil : (kind, n, rest)
  }

  private static func parse(_ lines: [[Unit]], depth: Int) -> [Block] {
    var out: [Block] = []
    var i = 0
    func quoted(_ line: [Unit]) -> Int? { depth < quoteDepth ? quoteMarker(lead(line)) : nil }
    while i < lines.count {
      let line = lines[i]
      if isBlank(line) {
        i += 1
        continue
      }
      if quoted(line) != nil {
        var inner: [[Unit]] = []
        while i < lines.count, let marker = quoted(lines[i]) {
          inner.append(Array(lines[i][marker...]))
          i += 1
        }
        out.append(.quote(parse(inner, depth: depth + 1)))
        continue
      }
      if let first = item(line) {
        var items: [[Line]] = []
        while i < lines.count {
          let next = item(lines[i])
          if let next, next.kind == first.kind {
            items.append([inline(next.rest)])
          } else if next == nil, !isBlank(lines[i]), lead(lines[i]).prefix(2).count == 2, lead(lines[i]).prefix(2).allSatisfy(isTab) {
            // An indented line straight under an item goes on with it,
            // whatever starts it.
            let from = lines[i].firstIndex { $0.scalar.map { !isSpace($0) } ?? true } ?? 0
            items[items.count - 1].append(inline(Array(lines[i][from...])))
          } else {
            break
          }
          i += 1
        }
        out.append(first.kind == .bullets ? .bullets(items) : .numbers(start: first.n, items))
        continue
      }
      var para: [Line] = []
      while i < lines.count, !isBlank(lines[i]), quoted(lines[i]) == nil, item(lines[i]) == nil {
        para.append(inline(lines[i]))
        i += 1
      }
      out.append(.para(para))
    }
    return out
  }

  // MARK: Emphasis

  private enum Kind { case space, punct, word }

  private static func kind(_ unit: Unit?) -> Kind {
    guard let unit else { return .space }
    guard let c = unit.scalar else { return .word }
    if isSpace(c) { return .space }
    switch c.properties.generalCategory {
    case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation, .initialPunctuation,
         .finalPunctuation, .otherPunctuation, .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol:
      return .punct
    default:
      return .word
    }
  }

  private static func isEscapable(_ c: Unicode.Scalar) -> Bool {
    switch c.value {
    case 0x21...0x2F, 0x3A...0x40, 0x5B...0x60, 0x7B...0x7E, 0x2022: true
    default: false
    }
  }

  /// Backslash escapes: the backslash goes, and what it kept is never markup.
  private static func unescaped(_ units: [Unit]) -> [Unit] {
    var out: [Unit] = []
    var i = 0
    while i < units.count {
      if units[i].bare == "\\", i + 1 < units.count, let next = units[i + 1].scalar, isEscapable(next) {
        out.append(.char(next, literal: true))
        i += 2
      } else {
        out.append(units[i])
        i += 1
      }
    }
    return out
  }

  private final class Run {
    let c: Unicode.Scalar
    var start: Int
    var end: Int
    let open: Bool
    let close: Bool

    init(c: Unicode.Scalar, start: Int, end: Int, open: Bool, close: Bool) {
      self.c = c
      self.start = start
      self.end = end
      self.open = open
      self.close = close
    }
  }

  private struct Pair { var open: Int; var close: Int; var use: Int }

  /// Which runs of * and _ pair, as CommonMark's emphasis, kept strict: no run
  /// inside a word opens or closes, and nothing pairs across a line.
  private static func pairs(_ units: [Unit]) -> [Pair] {
    var runs: [Run] = []
    var i = 0
    while i < units.count {
      guard let c = units[i].bare, c == "*" || c == "_" else {
        i += 1
        continue
      }
      var end = i + 1
      while end < units.count, units[end].bare == c { end += 1 }
      let before = kind(i > 0 ? units[i - 1] : nil)
      let after = kind(end < units.count ? units[end] : nil)
      let left = after != .space && (after != .punct || before != .word)
      let right = before != .space && (before != .punct || after != .word)
      runs.append(Run(c: c, start: i, end: end,
                      open: left && (!right || before == .punct),
                      close: right && (!left || after == .punct)))
      i = end
    }
    var found: [Pair] = []
    var stack: [Run] = []
    for run in runs {
      while run.close, run.end > run.start {
        guard let at = stack.lastIndex(where: { $0.c == run.c }) else { break }
        let opener = stack[at]
        let use = opener.end - opener.start >= 2 && run.end - run.start >= 2 ? 2 : 1
        found.append(Pair(open: opener.end - use, close: run.start, use: use))
        opener.end -= use
        run.start += use
        stack.removeSubrange((opener.end > opener.start ? at + 1 : at)...)
      }
      if run.open, run.end > run.start { stack.append(run) }
    }
    return found
  }

  private static func inline(_ raw: [Unit]) -> Line {
    let units = unescaped(raw)
    var hidden = Set<Int>()
    var strong = [Int](repeating: 0, count: units.count + 1)
    var em = [Int](repeating: 0, count: units.count + 1)
    for pair in pairs(units) {
      for k in 0..<pair.use {
        hidden.insert(pair.open + k)
        hidden.insert(pair.close + k)
      }
      if pair.use == 2 {
        strong[pair.open + pair.use] += 1
        strong[pair.close] -= 1
      } else {
        em[pair.open + pair.use] += 1
        em[pair.close] -= 1
      }
    }
    var out: Line = []
    var s = 0
    var e = 0
    for (i, unit) in units.enumerated() {
      s += strong[i]
      e += em[i]
      if hidden.contains(i) { continue }
      let marks = Marks(strong: s > 0, em: e > 0)
      switch unit {
      case .atom(let part):
        out.append(.atom(part, marks))
      case .char(let c, _):
        if case .text(let text, let kept)? = out.last, kept == marks {
          var more = text
          more.unicodeScalars.append(c)
          out[out.count - 1] = .text(more, marks)
        } else {
          out.append(.text(String(Character(c)), marks))
        }
      }
    }
    return out
  }
}
