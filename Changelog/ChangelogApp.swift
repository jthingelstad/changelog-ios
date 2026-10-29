import SwiftUI

@main
struct ChangelogApp: App {
  @State private var model = AppModel()
  @Environment(\.scenePhase) private var scenePhase

  init() {
    PhoneReminders.start()
  }

  var body: some Scene {
    let model = self.model
    WindowGroup {
      RootView()
        .environment(model)
        .task { await model.start() }
        .onChange(of: scenePhase) { _, phase in
          if phase == .active, model.phase == .signedIn { Task { await model.refresh() } }
        }
    }
    .backgroundTask(.appRefresh(PhoneReminders.refreshTask)) { await model.backgroundRefresh() }
  }
}

struct RootView: View {
  @Environment(AppModel.self) private var model
  @State private var tab = RootView.firstTab

  var body: some View {
    switch model.phase {
    case .starting:
      ProgressView()
    case .signedOut:
      SignInView()
    case .signedIn:
      TabView(selection: $tab) {
        Tab("Log", systemImage: "square.and.pencil", value: "log") { LogView() }
        Tab("Activity", systemImage: "list.bullet.rectangle", value: "activity") { ActivityView() }
        Tab("Settings", systemImage: "gearshape", value: "settings") { SettingsView() }
      }
    }
  }

  /// Log, or in a debug build the tab SIMCTL_CHILD_CHANGELOG_TAB names, for
  /// screenshots of the dev server's fictional account.
  static var firstTab: String {
    #if DEBUG
    ProcessInfo.processInfo.environment["CHANGELOG_TAB"] ?? "log"
    #else
    "log"
    #endif
  }
}

/// Monospace for versions, as the web and the email show them.
extension Font {
  static let version = Font.system(.title2, design: .monospaced).weight(.semibold)
  static let versionSmall = Font.system(.footnote, design: .monospaced)
}

enum Links {
  static let site = URL(string: "https://notes.yourversionnumber.com/")!
  static let guide = URL(string: "https://notes.yourversionnumber.com/guide/")!
  static let delete = URL(string: "https://notes.yourversionnumber.com/delete/")!
  static let settings = URL(string: "https://notes.yourversionnumber.com/settings/")!
}
