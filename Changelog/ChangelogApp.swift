import SwiftUI

@main
struct ChangelogApp: App {
  @State private var model: AppModel
  @Environment(\.scenePhase) private var scenePhase

  init() {
    PhoneReminders.start()
    let model = AppModel()
    _model = State(initialValue: model)
    // iOS can start the app just to deliver a visit, with no window: this has
    // to be listening, and the queue ready to take it.
    CheckInRecorder.shared.attach { await model.report($0) }
    #if DEBUG
    VisitsTest.standIn()
    #endif
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
          if phase == .active { CheckInRecorder.shared.refresh() }
          if phase == .active, model.phase == .signedIn { Task { await model.refresh() } }
          // Off the screen, iOS may end the app before it is back: the
          // draft is kept now, not a moment later.
          if phase != .active { model.keepDraft() }
          if phase == .background { model.lockReading() }
        }
        // A widget's link: Log, ready to write, or a check-in.
        .onOpenURL { url in
          if url == AppRoute.newNoteURL { AppRoute.shared.newNote() }
          if url == AppRoute.checkInURL { AppRoute.shared.checkIn(confirming: true) }
        }
    }
    .backgroundTask(.appRefresh(PhoneReminders.refreshTask)) { await model.backgroundRefresh() }
  }
}

struct RootView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.scenePhase) private var scenePhase
  @State private var tab = RootView.firstTab
  @State private var confirmingCheckIn = false

  var body: some View {
    switch model.phase {
    case .starting:
      ProgressView()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.paper)
    case .signedOut:
      SignInView()
        // Nothing to check in to: it mustn't happen later, on signing in.
        .onChange(of: AppRoute.shared.checkInAsked, initial: true) { _, asked in
          if asked { AppRoute.shared.checkInAsked = false; AppRoute.shared.checkInConfirms = false }
        }
    case .signedIn:
      TabView(selection: $tab) {
        Tab("Log", systemImage: "square.and.pencil", value: "log") { LogView() }
        Tab("Notes", systemImage: "book", value: "notes") { NotesView() }
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
      // The Check In control, or its link. The app is on the screen by now, so
      // the fix can be taken. The link asks first.
      .onChange(of: AppRoute.shared.checkInAsked, initial: true) { _, asked in
        guard asked else { return }
        AppRoute.shared.checkInAsked = false
        if AppRoute.shared.checkInConfirms {
          AppRoute.shared.checkInConfirms = false
          confirmingCheckIn = true
        } else {
          Task { await model.checkInFromOutside() }
        }
      }
      .alert("Check in here?", isPresented: $confirmingCheckIn) {
        Button("Check In") { Task { await model.checkInFromOutside() } }
        Button("Cancel", role: .cancel) {}
      } message: {
        Text("A link opened Changelog to add where you are to Release Notes.")
      }
      // With the lock on, the app switcher's picture shows no note, nor any
      // sheet or file open over the tabs.
      .background { PrivacyCover(shows: model.lockOn && model.readsNotes && scenePhase != .active) }
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
