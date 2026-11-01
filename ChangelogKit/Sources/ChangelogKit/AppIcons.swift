/// The app's icons, from the 2026-11-01 icon study (scripts/make_icons.sh,
/// which names the sets in the app's asset catalog by these raw values):
/// Versions, and four editions for Supporting Members of the Weekly Thing
/// (Jamie, 2026-11-01: "Approved: Changelog member icons unlock for
/// Supporting Members"). `/v1/me`'s `supporting_member` (API 1.12.0) says
/// who may choose them.
public enum AppIcon: String, CaseIterable, Identifiable, Sendable {
  case versions = "AppIcon"
  case paper = "AppIcon-Paper"
  case copper = "AppIcon-Copper"
  case terminal = "AppIcon-Terminal"
  case afterglow = "AppIcon-Afterglow"

  public var id: String { rawValue }
  /// What `setAlternateIconName` takes: nil is the primary icon.
  public var alternateName: String? { self == .versions ? nil : rawValue }
  /// The small copy Settings shows (an imageset beside each icon set), since
  /// an icon set can't be drawn as an image.
  public var preview: String { rawValue + "-Preview" }
  public var title: String {
    switch self {
    case .versions: "Versions"
    case .paper: "Paper"
    case .copper: "Copper"
    case .terminal: "Terminal"
    case .afterglow: "Afterglow"
    }
  }

  public static func named(_ name: String?) -> AppIcon {
    name.flatMap(AppIcon.init(rawValue:)) ?? .versions
  }

  /// The icons a picker offers. A member chooses among all five. Anyone else
  /// sees nothing, and nothing about them, since the app may not point to
  /// buying outside it (docs/API.md in Release Notes), unless an icon chosen
  /// as a member is still on: then that one and Versions, to go back. A
  /// lapsed membership never changes the icon by itself, since iOS shows an
  /// alert whenever it changes, which should only ever follow a tap.
  public static func offered(member: Bool, current: AppIcon) -> [AppIcon] {
    if member { return allCases }
    return current == .versions ? [] : [.versions, current]
  }
}
