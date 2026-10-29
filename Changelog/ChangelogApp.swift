import SwiftUI

@main
struct ChangelogApp: App {
  @State private var model = AppModel()
  @Environment(\.scenePhase) private var scenePhase

  var body: some Scene {
    WindowGroup {
      RootView()
        .environment(model)
        .task { await model.start() }
        .onChange(of: scenePhase) { _, phase in
          if phase == .active, model.phase == .signedIn { Task { await model.refresh() } }
        }
    }
  }
}

struct RootView: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    switch model.phase {
    case .starting:
      ProgressView()
    case .signedOut:
      SignInView()
    case .signedIn:
      TabView {
        Tab("Log", systemImage: "square.and.pencil") { LogView() }
        Tab("Activity", systemImage: "list.bullet.rectangle") { ActivityView() }
        Tab("Settings", systemImage: "gearshape") { SettingsView() }
      }
    }
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
