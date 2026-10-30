import CoreText
import SwiftUI

// Release Notes' look, from its web app (web/src/styles/site.css in
// jthingelstad/yvn-release-notes): type on paper. Colours are the email's,
// light then dark. No borders around things, no boxes, no shadows: rules
// under fields and the tangerine Commit are the only marks. The tab bar,
// sheets and menus stay as iOS draws them. Change a colour there first.

extension Color {
  static let paper = Color(light: 0xFFFBF2, dark: 0x14163A)
  static let ink = Color(light: 0x14163A, dark: 0xFFFBF2)
  static let ink2 = Color(light: 0x3B3D63, dark: 0xC9CBE6)
  static let ink3 = Color(light: 0x6E7092, dark: 0x8A8CA8)
  /// The same as AccentColor: links, tags, actions, a version's digits.
  static let cobalt = Color(light: 0x1A4FE0, dark: 0x8FB0FF)
  /// Commit, a focused field's rule, a version's dots.
  static let tangerine = Color(light: 0xFF5A1F, dark: 0xFF5A1F)
  /// Problems and refusals, in place of the system's orange.
  static let tangerineInk = Color(light: 0xC43C00, dark: 0xFF8A5C)
  /// Words on tangerine, navy in both appearances.
  static let onTangerine = Color(light: 0x14163A, dark: 0x14163A)

  init(light: UInt32, dark: UInt32) {
    self.init(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(rgb: dark) : UIColor(rgb: light) })
  }
}

private extension UIColor {
  convenience init(rgb: UInt32) {
    self.init(red: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
              blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
  }
}

/// The two faces the web serves, bundled (OFL, Fonts/) and named in
/// Info.plist's UIAppFonts. Each is one variable font whose default
/// instance is neither the weight nor the width wanted (Bricolage's is
/// 96pt ExtraBold, Martian Mono's SemiExpanded), so every axis is set.
struct Face {
  enum Family { case bricolage, martian }

  var family: Family
  var size: CGFloat
  var weight: CGFloat
  var style: Font.TextStyle
  /// Letter spacing in ems, as the CSS writes it.
  var tracking: CGFloat = 0
  /// Past this, Dynamic Type grows it no more (the version, which must fit
  /// on one line).
  var largest: CGFloat = .infinity

  static let display = Face(family: .bricolage, size: 64, weight: 800, style: .largeTitle, tracking: -0.025, largest: 88)
  static let title = Face(family: .bricolage, size: 34, weight: 800, style: .largeTitle, tracking: -0.01)
  static let section = Face(family: .bricolage, size: 26, weight: 800, style: .title, tracking: -0.015)
  static let brand = Face(family: .bricolage, size: 18, weight: 800, style: .headline)
  static let writing = Face(family: .bricolage, size: 20, weight: 400, style: .body)
  static let note = Face(family: .bricolage, size: 17, weight: 400, style: .body)
  static let line = Face(family: .bricolage, size: 17, weight: 600, style: .body)
  static let commit = Face(family: .bricolage, size: 17, weight: 800, style: .body)
  static let action = Face(family: .bricolage, size: 16, weight: 600, style: .callout)
  static let lede = Face(family: .bricolage, size: 17, weight: 400, style: .body)
  static let hint = Face(family: .bricolage, size: 15, weight: 400, style: .subheadline)
  static let tag = Face(family: .bricolage, size: 15, weight: 500, style: .subheadline)
  static let tagOn = Face(family: .bricolage, size: 15, weight: 700, style: .subheadline)
  static let head = Face(family: .bricolage, size: 14, weight: 600, style: .subheadline)
  static let meta = Face(family: .bricolage, size: 13, weight: 400, style: .footnote)
  /// Datelines: small capitals in mono, spaced out.
  static let dateline = Face(family: .martian, size: 12, weight: 400, style: .caption, tracking: 0.1)
  /// A version or a time inside a line.
  static let stamp = Face(family: .martian, size: 13, weight: 700, style: .footnote)
  static let time = Face(family: .martian, size: 12, weight: 400, style: .caption)

  func font(size: CGFloat) -> Font {
    var axes: [NSNumber: NSNumber] = [NSNumber(value: Self.wght): NSNumber(value: Double(weight)),
                                      NSNumber(value: Self.wdth): NSNumber(value: 100.0)]
    // The web's optical sizing is automatic: the axis follows the size.
    if family == .bricolage { axes[NSNumber(value: Self.opsz)] = NSNumber(value: Double(min(max(size, 12), 96))) }
    let name = family == .bricolage ? "BricolageGrotesque-96ptExtraBold" : "MartianMono-SemiExpandedRegular"
    let attributes: [CFString: Any] = [kCTFontNameAttribute: name, kCTFontVariationAttribute: axes]
    return Font(CTFontCreateWithFontDescriptor(CTFontDescriptorCreateWithAttributes(attributes as CFDictionary), size, nil))
  }

  // The axes' tags, as CoreText names them: 'wght', 'wdth', 'opsz'.
  private static let wght: UInt32 = 0x7767_6874
  private static let wdth: UInt32 = 0x7764_7468
  private static let opsz: UInt32 = 0x6F70_737A
}

/// A face at the size Dynamic Type asks for.
private struct FaceModifier: ViewModifier {
  let face: Face
  @ScaledMetric private var size: CGFloat

  init(_ face: Face) {
    self.face = face
    _size = ScaledMetric(wrappedValue: face.size, relativeTo: face.style)
  }

  func body(content: Content) -> some View {
    let points = min(size, face.largest)
    content.font(face.font(size: points)).tracking(face.tracking * points)
  }
}

extension View {
  func face(_ face: Face) -> some View { modifier(FaceModifier(face)) }

  /// A row of a plain list laid on the paper: no separator, no box, the
  /// web's side margins.
  func paperRow(top: CGFloat = 0, bottom: CGFloat = 0) -> some View {
    listRowBackground(Color.paper)
      .listRowSeparator(.hidden)
      .listRowInsets(EdgeInsets(top: top, leading: 24, bottom: bottom, trailing: 24))
  }

  /// A screen's list on the paper.
  func paperList() -> some View {
    listStyle(.plain)
      .scrollContentBackground(.hidden)
      .background(Color.paper)
      .foregroundStyle(Color.ink)
  }
}

/// A version as the web sets one in a line: cobalt digits, tangerine dots.
func versionText(_ version: String) -> Text {
  version.reduce(Text(verbatim: "")) { line, character in
    let piece = Text(verbatim: String(character)).foregroundStyle(character == "." ? Color.tangerine : Color.cobalt)
    return Text("\(line)\(piece)")
  }
}

/// Release Notes' mark: a version, its dot, and two written lines.
struct BrandMark: View {
  var body: some View {
    Canvas { context, size in
      let s = min(size.width, size.height) / 100
      var v = Path()
      v.addLines([CGPoint(x: 12, y: 12), CGPoint(x: 31, y: 12), CGPoint(x: 45, y: 50), CGPoint(x: 59, y: 12),
                  CGPoint(x: 78, y: 12), CGPoint(x: 57, y: 64), CGPoint(x: 33, y: 64)].map { $0.applying(.init(scaleX: s, y: s)) })
      v.closeSubpath()
      var lines = Path()
      lines.addRoundedRect(in: CGRect(x: 18 * s, y: 72 * s, width: 68 * s, height: 6 * s), cornerSize: CGSize(width: 3 * s, height: 3 * s))
      lines.addRoundedRect(in: CGRect(x: 18 * s, y: 85 * s, width: 46 * s, height: 6 * s), cornerSize: CGSize(width: 3 * s, height: 3 * s))
      context.fill(v, with: .color(.cobalt))
      context.fill(lines, with: .color(.cobalt))
      context.fill(Path(ellipseIn: CGRect(x: 67 * s, y: 43 * s, width: 22 * s, height: 22 * s)), with: .color(.tangerine))
    }
    .frame(width: 24, height: 24)
    .accessibilityHidden(true)
  }
}

/// The bar along the top of a screen: the mark, the name, and what the
/// screen puts at the end (a streak, an action).
struct BrandBar<Trailing: View>: View {
  @ViewBuilder var trailing: Trailing

  var body: some View {
    HStack(spacing: 8) {
      BrandMark()
      Text("Changelog").face(.brand).foregroundStyle(Color.ink)
      Spacer(minLength: 12)
      trailing
    }
    .frame(minHeight: 44)
  }
}

extension BrandBar where Trailing == EmptyView {
  init() { self.init { EmptyView() } }
}

/// A screen's title and the line under it, where the web puts its h1.
struct PageTitle: View {
  let title: String
  let lede: String

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(title).face(.title).foregroundStyle(Color.ink).accessibilityAddTraits(.isHeader)
      Text(lede).face(.lede).foregroundStyle(Color.ink2)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// The web's one filled button: tangerine, navy words, square-ish corners.
struct CommitButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var enabled

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .face(.commit)
      .foregroundStyle(Color.onTangerine)
      .padding(.horizontal, 22)
      .frame(minHeight: 48)
      .background(Color.tangerine, in: .rect(cornerRadius: 8))
      .opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
  }
}

/// An action as words: cobalt, no box, at least 44 points tall.
struct QuietButtonStyle: ButtonStyle {
  var color: Color = .cobalt
  @Environment(\.isEnabled) private var enabled

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .face(.action)
      .foregroundStyle(color)
      .frame(minHeight: 44)
      .contentShape(.rect)
      .opacity(enabled ? (configuration.isPressed ? 0.6 : 1) : 0.45)
  }
}
