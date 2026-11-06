import AppIntents
import Observation

/// Where the app goes next: the tab a tapped notification names, or a new
/// note that a shortcut, the Action Button, a control or a widget asked
/// for. Held until the app's window takes it, since each can start the app
/// before the window is there.
@MainActor @Observable
final class AppRoute {
  static let shared = AppRoute()
  var tab: String?
  /// Counts the asks for a new note, so a second ask still brings up the
  /// keyboard.
  private(set) var newNotes = 0

  /// A check-in asked for from outside the app's screens, until the signed-in
  /// app takes it.
  var checkInAsked = false

  func newNote() {
    tab = "log"
    newNotes += 1
  }

  /// Activity, where the stop shows, and it says so there.
  func checkIn() {
    tab = "activity"
    checkInAsked = true
  }

  /// The link a widget opens: Log, ready to write.
  static let newNoteURL = URL(string: "com.yourversionnumber.changelog:new-note")!
  /// The same for a check-in.
  static let checkInURL = URL(string: "com.yourversionnumber.changelog:check-in")!
}

/// Opens Changelog on Log with the keyboard up. Built into the app and the
/// widget extension both, so a control can name it; it always runs in the
/// app.
struct NewNoteIntent: AppIntent {
  static let title: LocalizedStringResource = "New Note"
  static var description: IntentDescription { IntentDescription("Opens Changelog ready to write a note.") }
  static var supportedModes: IntentModes { .foreground }

  @MainActor
  func perform() async throws -> some IntentResult {
    AppRoute.shared.newNote()
    return .result()
  }
}

/// Opens Changelog and checks in where you are. A widget never calls the API,
/// and a fix in the background is unproven, so this runs in the app, which
/// takes one fix as Check in now does.
struct CheckInIntent: AppIntent {
  static let title: LocalizedStringResource = "Check In"
  static var description: IntentDescription { IntentDescription("Opens Changelog and checks in where you are.") }
  static var supportedModes: IntentModes { .foreground }

  @MainActor
  func perform() async throws -> some IntentResult {
    AppRoute.shared.checkIn()
    return .result()
  }
}
