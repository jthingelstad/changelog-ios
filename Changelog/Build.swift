import Foundation
import SwiftUI

/// Which build this is, stamped in by `scripts/version.sh`: its version,
/// counted from Changelog's start on 29 October 2026 by Your Version
/// Number's arithmetic, the commit it was made from, and when.
enum Build {
  static let version = info("CFBundleShortVersionString") ?? "0.0.0"
  static let commit = info("ChangelogCommit").flatMap { $0.count == 40 ? $0 : nil }
  static let madeAt = info("ChangelogBuiltAt").flatMap { try? Date($0, strategy: .iso8601) }

  static var commitURL: URL? {
    commit.flatMap { URL(string: "https://github.com/jthingelstad/changelog-ios/commit/\($0)") }
  }

  /// "Changelog 0.0.0, build 571b43d, made Oct 29 at 1:25 PM CDT.", as
  /// Release Notes' Settings names its own build, the commit linked.
  static var line: AttributedString {
    var build = AttributedString(commit.map { String($0.prefix(7)) } ?? "dev")
    build.link = commitURL
    build.font = .footnote.monospaced()
    var number = AttributedString(version)
    number.font = .footnote.monospaced()
    var line = AttributedString("Changelog ") + number + AttributedString(", build ") + build
    if let madeAt {
      let day = madeAt.formatted(.dateTime.month(.abbreviated).day())
      let time = madeAt.formatted(.dateTime.hour().minute())
      let zone = madeAt.formatted(.dateTime.timeZone(.specificName(.short)))
      line += AttributedString(", made \(day) at \(time) \(zone)")
    }
    return line + AttributedString(".")
  }

  private static func info(_ key: String) -> String? {
    Bundle.main.object(forInfoDictionaryKey: key) as? String
  }
}
