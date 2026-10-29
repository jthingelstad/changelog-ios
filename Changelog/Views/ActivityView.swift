import ChangelogKit
import SwiftUI

/// The activity log, newest first, from every channel: what came in, what
/// changed, what went out. It never shows what a note said; the server
/// leaves the words out.
struct ActivityView: View {
  @Environment(AppModel.self) private var model
  @State private var items: [ActivityItem] = []
  @State private var next: String?
  @State private var filter: Filter = .all
  @State private var loading = false
  /// The newest row seen when this screen was last left, kept on the phone
  /// so the server stores nothing new.
  @AppStorage("activity.seen") private var seen = ""
  @State private var seenAtOpen = ""

  enum Filter: String, CaseIterable, Identifiable {
    case all = "All", notes = "Notes", email = "Email", badges = "Badges", upcoming = "Upcoming", connections = "Connections", problems = "Problems"
    var id: String { rawValue }
    var kinds: [String] {
      switch self {
      case .all: []
      case .notes: ["note", "transcript", "description", "import"]
      case .email: ["mail", "email", "reminder"]
      case .badges: ["badge"]
      case .upcoming: ["upcoming", "reminder"]
      case .connections: ["connection", "reads"]
      case .problems: ["mail", "status", "connection"]
      }
    }
  }

  var body: some View {
    NavigationStack {
      List {
        Picker("Show", selection: $filter) {
          ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.menu)

        if !model.hasActivity {
          Text("This token can't read the activity log. Make one with Activity ticked to see it here.")
            .foregroundStyle(.secondary)
        }
        ForEach(shown) { item in
          if item.id == seenAtOpen, item.id != items.first?.id {
            Text("Since you last looked").font(.caption).foregroundStyle(.secondary).listRowSeparator(.hidden)
          }
          ActivityRow(item: item)
        }
        if next != nil {
          Button("Older") { Task { await load(more: true) } }.disabled(loading)
        }
      }
      .navigationTitle("Activity")
      .refreshable { await load() }
      .task(id: filter) { await load() }
      .onAppear { seenAtOpen = seen }
      .onDisappear { if let first = items.first { seen = first.id } }
    }
  }

  private var shown: [ActivityItem] {
    filter == .problems ? items.filter(\.isProblem) : items
  }

  private func load(more: Bool = false) async {
    guard model.hasActivity else { return }
    loading = true
    defer { loading = false }
    guard let page = await model.activity(before: more ? next : nil, kinds: filter.kinds) else { return }
    items = more ? items + page.items : page.items
    next = page.next
  }
}

struct ActivityRow: View {
  let item: ActivityItem

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack {
        Text(item.headline)
        Spacer()
        Text(item.time).font(.caption).foregroundStyle(.secondary).monospacedDigit()
      }
      if let detail = item.detail {
        Text(detail).font(.caption).foregroundStyle(.secondary)
      }
    }
    .accessibilityElement(children: .combine)
  }
}

extension AppModel {
  var hasActivity: Bool { me?.token.scopes.contains("activity") == true }
}

extension ActivityItem {
  /// Through what it came, in the owner's words.
  var source: String? {
    switch via {
    case "token": token.map { "via \($0)" } ?? "via a token"
    case "assistant": client.map { "by \($0)" } ?? "by an agent"
    case "email": "by email"
    case "web": "on the web"
    case "import": "by import"
    default: nil
    }
  }

  var headline: String {
    let version = version.map { " \($0)" } ?? ""
    switch kind {
    case "note.added": return "Filed in\(version)"
    case "note.edited": return "Edited in\(version)"
    case "note.deleted": return "Deleted from\(version)"
    case "note.files": return "Files added in\(version)"
    case "mail": return outcome == "note" ? "Reply filed in\(version)" : "Email not filed"
    case "email.sent": return "Email sent for\(version)"
    case "reminder": return title.map { "Reminder: \($0)" } ?? "Reminder in the email"
    case "badge.earned": return name.map { "Badge: \($0)" } ?? "Badge earned"
    case "transcript.added": return "Recording written out"
    case "description.added": return "Photos described"
    case "import.notes": return "Notes imported"
    case "upcoming.added", "upcoming.changed", "upcoming.removed":
      let verb = kind == "upcoming.added" ? "added" : kind == "upcoming.changed" ? "changed" : "removed"
      return title.map { "\($0) \(verb)" } ?? "Upcoming date \(verb)"
    case "connection.added": return "Connected \(client ?? "a client")"
    case "connection.changed": return "\(client ?? "A connection") changed"
    case "connection.removed": return "\(client ?? "A connection") disconnected"
    case "reads": return "\(client ?? "An agent") read your notes"
    case "status.stopped": return "Email stopped"
    case "status.restarted": return "Email restarted"
    case "signin": return "Signed in on the web"
    case "settings.changed": return "Settings changed"
    case "pause.set": return "Email paused"
    case "pause.ended": return "Pause ended"
    case "place.set", "place.removed": return "Place for the day changed"
    default: return kind.replacingOccurrences(of: ".", with: " ").capitalized
    }
  }

  var detail: String? {
    let parts = [source, day].compactMap { $0 }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }

  var isProblem: Bool {
    (kind == "mail" && outcome != "note") || kind == "status.stopped" || kind == "connection.removed"
  }

  var time: String {
    guard let date = try? Date(at, strategy: .iso8601) else { return "" }
    return Calendar.current.isDateInToday(date) ? date.formatted(date: .omitted, time: .shortened) : date.formatted(.dateTime.month().day())
  }
}
