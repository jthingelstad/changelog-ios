// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "ChangelogKit",
  platforms: [.iOS("26.0"), .macOS("15.0")],
  products: [.library(name: "ChangelogKit", targets: ["ChangelogKit"])],
  targets: [
    .target(name: "ChangelogKit"),
    .testTarget(name: "ChangelogKitTests", dependencies: ["ChangelogKit"]),
  ]
)
