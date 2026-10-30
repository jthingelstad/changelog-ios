import ChangelogKit
import SwiftUI

/// Settings' daily prompt and activity notifications (0.3), each off until
/// turned on here. The Upcoming reminders toggle sits just above.
struct NotificationSettings: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    Section {
      Toggle("Ask me each morning", isOn: Binding(
        get: { model.promptOn },
        set: { on in Task { await model.setPrompt(on) } }))
    } header: {
      SectionHead("Daily prompt")
    } footer: {
      SectionNote(model.promptProblem ?? promptFooter, problem: model.promptProblem != nil)
    }

    Section {
      if model.hasActivity {
        ForEach(ActivityNoticeKind.allCases) { kind in
          Toggle(Self.name(kind), isOn: Binding(
            get: { model.activityNotices.contains(kind) },
            set: { on in Task { await model.setActivityNotice(kind, on) } }))
        }
      } else {
        Text("To get them here, make a token with “Read the activity log” ticked.")
          .foregroundStyle(Color.ink2)
      }
    } header: {
      SectionHead("Activity notifications")
    } footer: {
      SectionNote(model.activityProblem ?? "Notes from elsewhere: added by an agent, another token, an import or an email reply. Problems: an email that wasn't filed, your email stopping, a connection ending. Never this phone's own notes, and never the daily email. Changelog looks when iOS lets it refresh in the background, so they can come minutes or hours later.",
                  problem: model.activityProblem != nil)
    }
  }

  private var promptFooter: String {
    guard let me = model.me else { return "Each morning, when your email goes, a notification asks what changed. Tap it to write." }
    let when = Self.clock(me.sendTime).map { " at \($0)" } ?? ""
    return "“\(DailyPrompt.text(version: me.version))” when your email goes\(when), with that day's version. Tap it to write."
  }

  static func name(_ kind: ActivityNoticeKind) -> String {
    switch kind {
    case .others: "Notes from elsewhere"
    case .problems: "Problems"
    case .badges: "Badges earned"
    }
  }

  /// "06:30", the account's send time, as this phone writes a time.
  static func clock(_ time: String) -> String? {
    let parts = time.split(separator: ":").compactMap { Int($0) }
    guard parts.count == 2, let date = Calendar(identifier: .gregorian).date(from: DateComponents(year: 2001, month: 1, day: 1, hour: parts[0], minute: parts[1]))
    else { return nil }
    return date.formatted(date: .omitted, time: .shortened)
  }
}
