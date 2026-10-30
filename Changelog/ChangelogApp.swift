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
        // Back online with the app open: what waits goes.
        .task { await model.watchConnection() }
        .onChange(of: scenePhase) { _, phase in
          if phase == .active, model.phase == .signedIn { Task { await model.refresh() } }
          // Off the screen, iOS may end the app before it is back: the
          // draft is kept now, not a moment later.
          if phase != .active { model.keepDraft() }
        }
        // A widget's link: Log, ready to write.
        .onOpenURL { url in
          if url == AppRoute.newNoteURL { AppRoute.shared.newNote() }
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.paper)
    case .signedOut:
      SignInView()
    case .signedIn:
      TabView(selection: $tab) {
        Tab("Log", systemImage: "square.and.pencil", value: "log") { LogView() }
        Tab("Upcoming", systemImage: "calendar", value: "upcoming") { UpcomingView() }
        Tab("Activity", systemImage: "list.bullet.rectangle", value: "activity") { ActivityView() }
        Tab("Settings", systemImage: "gearshape", value: "settings") { SettingsView() }
      }
      // A tapped notification opens its tab: a reminder Upcoming, the
      // daily prompt Log, an activity notice Activity. A new note (a
      // shortcut, a control, a widget) opens Log.
      .onChange(of: AppRoute.shared.tab, initial: true) { _, asked in
        guard let asked else { return }
        tab = asked
        AppRoute.shared.tab = nil
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

enum Links {
  static let site = URL(string: "https://notes.yourversionnumber.com/")!
  static let guide = URL(string: "https://notes.yourversionnumber.com/guide/")!
  static let delete = URL(string: "https://notes.yourversionnumber.com/delete/")!
  static let settings = URL(string: "https://notes.yourversionnumber.com/settings/")!
  static let privacy = URL(string: "https://notes.yourversionnumber.com/privacy/")!
}
