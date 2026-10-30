import AppIntents
import ChangelogKit
import WidgetKit

/// Adds a note from Shortcuts, Siri or the Action Button without opening
/// the app. It goes as a share does (`QuickNote`): from a queue of its own
/// in the App Group, within a few seconds, else left for the app under the
/// same key. What it says back is never the note's words, since Siri may
/// say it aloud.
struct AddNoteIntent: AppIntent {
  static let title: LocalizedStringResource = "Add a Note"
  static var description: IntentDescription {
    IntentDescription("Adds a note to today in Release Notes, with your sticky tag, without opening Changelog.")
  }
  static var supportedModes: IntentModes { .background }
  /// Works with the phone locked (Jamie, 2026-10-29): the token and the share
  /// queue can be read once the phone has been unlocked since it started.
  /// Whoever holds the phone can add a note, never read one.
  static var authenticationPolicy: IntentAuthenticationPolicy { .alwaysAllowed }

  @Parameter(title: "Note", inputOptions: String.IntentInputOptions(multiline: true), requestValueDialog: "What changed?")
  var text: String

  static var parameterSummary: some ParameterSummary { Summary("Add \(\.$text) to Release Notes") }

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw $text.needsValueError("What changed?") }
    let words = QuickNote.words(text)
    guard let inbox = ShareInbox.shared else { throw AddNoteProblem.noGroup }
    let share = inbox.open()
    do {
      try await share.outbox.enqueue(.post(NotePost(text: words, writtenAt: Timestamp.string(.now))))
    } catch {
      try? FileManager.default.removeItem(at: share.file)
      throw AddNoteProblem.notKept
    }
    // Siri doesn't wait long: what isn't sent in 5 seconds, the app sends,
    // well inside Siri's own patience, so it never asks to be said again
    // (which would be a second note).
    let outcome = await QuickNote.send(share, from: inbox, with: QuickNote.client(userAgent: AppModel.userAgent), within: .seconds(5))
    if case .filed(let receipt) = outcome {
      if WidgetSnapshot.filed(on: receipt.note.date) { WidgetCenter.shared.reloadAllTimelines() }
      // Written today: today's prompt has nothing left to ask.
      if UserDefaults.standard.bool(forKey: "prompt") { PhoneReminders.takeBack([DailyPrompt.id(receipt.note.date)]) }
    }
    return .result(dialog: IntentDialog(stringLiteral: QuickNote.said(outcome)))
  }
}

enum AddNoteProblem: Error, CustomLocalizedStringResourceConvertible {
  case noGroup, notKept

  var localizedStringResource: LocalizedStringResource {
    switch self {
    case .noGroup: "This build of Changelog can't send from here. Open Changelog and write the note there."
    case .notKept: "This phone couldn't save that to send. Free up some space and try again."
    }
  }
}

/// What Siri and Spotlight offer without any setup. Siri asks for the
/// words: a phrase can't carry free text.
struct ChangelogShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(intent: AddNoteIntent(), phrases: [
      "Add a note in \(.applicationName)",
      "Add a note to \(.applicationName)",
      "Log a change in \(.applicationName)",
    ], shortTitle: "Add a Note", systemImageName: "text.badge.plus")
    AppShortcut(intent: NewNoteIntent(), phrases: [
      "New note in \(.applicationName)",
      "Write in \(.applicationName)",
    ], shortTitle: "New Note", systemImageName: "square.and.pencil")
  }
}
