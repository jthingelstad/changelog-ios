import ChangelogKit
import SwiftUI

/// The activity log, newest first, from every channel: what came in, what
/// changed, what went out. It never shows what a note said; the server
/// leaves the words out. With reading open, a row about a note opens it, read
/// as it opens and held in memory only.
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
  @State private var path = NavigationPath()
  /// A row was opened, so coming back finds the list as it was, however far
  /// back it had been paged.
  @State private var cameBack = false

  enum Filter: String, CaseIterable, Identifiable {
    case all = "All", notes = "Notes", checkIns = "Check-ins", email = "Email", badges = "Badges", upcoming = "Upcoming", connections = "Connections", problems = "Problems"
    var id: String { rawValue }
    var kinds: [String] {
      switch self {
      case .all: []
      case .notes: ["note", "transcript", "description", "import"]
      case .checkIns: ["checkin"]
      case .email: ["mail", "email", "reminder"]
      case .badges: ["badge"]
      case .upcoming: ["upcoming", "reminder"]
      case .connections: ["connection", "reads"]
      case .problems: ["mail", "status", "connection"]
      }
    }
  }

  var body: some View {
    NavigationStack(path: $path) {
      List {
        Group {
          BrandBar()
          PageTitle(title: "Activity", lede: "What came in, changed and went out, from every channel.")
            .padding(.top, 22)
          // The filters as words, the one picked underlined in tangerine,
          // as the web marks the page you're on.
          ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 16) {
              ForEach(Filter.allCases) { choice in
                let on = choice == filter
                Button { filter = choice } label: {
                  Text(choice.rawValue)
                    .underline(on, color: .tangerine)
                    .face(on ? .tagOn : .tag)
                    .foregroundStyle(on ? Color.ink : Color.cobalt)
                    .frame(minHeight: 44)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
              }
            }
          }
          .accessibilityElement(children: .contain)
          .accessibilityLabel("Show")
          .padding(.top, 8)
          HStack(alignment: .top, spacing: 20) {
            CheckInNowButton()
            if model.hasActivity {
              Button("Map of check-ins") { path.append(CheckInMapRoute()) }
                .buttonStyle(QuietButtonStyle())
            }
          }
          .padding(.top, 4)
        }
        .paperRow()

        if !model.hasActivity {
          Text("This token can't read the activity log. Make one with “Read the activity log” ticked to see it here.")
            .face(.hint)
            .foregroundStyle(Color.ink2)
            .paperRow(top: 12)
        }
        ForEach(shown) { item in
          if item.id == seenAtOpen, item.id != items.first?.id {
            HStack(spacing: 10) {
              Text("Since you last looked")
                .textCase(.uppercase)
                .face(.dateline)
                .foregroundStyle(Color.tangerineInk)
                .fixedSize()
              Rectangle().fill(Color.tangerine).frame(height: 2)
            }
            .paperRow(top: 10, bottom: 4)
          }
          row(item)
            .paperRow(top: 8, bottom: 8)
        }
        if next != nil {
          Button("Older") { Task { await load(more: true) } }
            .buttonStyle(QuietButtonStyle())
            .disabled(loading)
            .paperRow(top: 8)
        }
        // Room to scroll the last row clear of the tab bar.
        Color.clear.frame(height: 24).paperRow()
      }
      .paperList()
      .navigationTitle("Activity")
      .toolbar(.hidden, for: .navigationBar)
      .refreshable { await load() }
      .task(id: filter) {
        if cameBack {
          cameBack = false
        } else {
          await load()
        }
      }
      .onAppear { if path.isEmpty { seenAtOpen = seen } }
      .onDisappear { if path.isEmpty, let first = items.first { seen = first.id } }
      .onChange(of: model.checkInChanges) { Task { await load() } }
      .overlay(alignment: .bottom) { Toast() }
      .navigationDestination(for: ActivityStop.self) { CheckInPage(day: $0.day, id: $0.id) }
      .navigationDestination(for: CheckInMapRoute.self) { _ in CheckInMapView() }
      .navigationDestination(for: ActivityNote.self) { ActivityNotePage(route: $0) }
      .navigationDestination(for: DayRoute.self) { DayPage(date: $0.date) }
      // A day's own rows open their notes.
      .navigationDestination(for: NoteDetail.self) { NotePage(note: $0) }
    }
    .onChange(of: path.isEmpty) { _, empty in
      if !empty { cameBack = true }
    }
    // Nothing a row opened stays open behind the lock.
    .onChange(of: model.readingOpen) { _, open in
      if !open { path = NavigationPath() }
    }
  }

  @ViewBuilder private func row(_ item: ActivityItem) -> some View {
    // A check-in opens even with reading locked (Jamie's call 4, in the design).
    switch item.opens {
    case .checkIn(let day, let id):
      NavigationLink(value: ActivityStop(day: day, id: id)) { ActivityRow(item: item) }
    case _ where !model.readingOpen:
      ActivityRow(item: item)
    case .note(let date, let id):
      NavigationLink(value: ActivityNote(date: date, id: id)) { ActivityRow(item: item) }
    case .day(let date):
      NavigationLink(value: DayRoute(date: date)) { ActivityRow(item: item) }
    case nil:
      ActivityRow(item: item)
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

struct ActivityStop: Hashable {
  let day: String
  let id: String
}

private struct ActivityNote: Hashable {
  let date: String
  let id: String
}

/// A note an activity row points at. The row has its id and day, not the note,
/// so it reads it here, and says so plainly if it has gone since.
private struct ActivityNotePage: View {
  @Environment(AppModel.self) private var model
  let route: ActivityNote
  @State private var note: NoteDetail?
  @State private var gone = false
  @State private var problem: String?

  var body: some View {
    if let note {
      NotePage(note: note)
    } else {
      List {
        Group {
          if gone {
            Text("This note is gone: it was deleted somewhere else.").face(.hint).foregroundStyle(Color.tangerineInk)
          } else if let problem {
            Text(problem).face(.hint).foregroundStyle(Color.tangerineInk)
            Button("Try again") { Task { await read() } }
              .buttonStyle(QuietButtonStyle())
          } else {
            ProgressView()
          }
        }
        .paperRow(top: 12, bottom: 8)
        .listRowSeparator(.hidden)
      }
      .paperList()
      .navigationTitle(Day.label(route.date, today: model.me?.today ?? route.date))
      .navigationBarTitleDisplayMode(.inline)
      .task { await read() }
    }
  }

  private func read() async {
    problem = nil
    do throws(APIError) {
      note = try await model.load(date: route.date, id: route.id, urls: true)
    } catch {
      if error.status == 404 { gone = true } else { problem = error.message }
    }
  }
}

struct ActivityRow: View {
  let item: ActivityItem
  /// What the note said, on Log's Today alone.
  var words: String?
  @Environment(\.dynamicTypeSize) private var size

  /// The time beside the headline, or under it at the accessibility sizes,
  /// where beside it would squeeze both.
  private var line: AnyLayout {
    size.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
      : AnyLayout(HStackLayout(alignment: .firstTextBaseline))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      line {
        // The headline has the room the time doesn't need, so it wraps
        // between words and is never hyphenated.
        Text(item.headline)
          .face(.line)
          .foregroundStyle(item.isProblem ? Color.tangerineInk : Color.ink)
          .layoutPriority(1)
        if !size.isAccessibilitySize { Spacer(minLength: 8) }
        // Always on one line.
        Text(item.time).face(.time).foregroundStyle(Color.ink3).monospacedDigit().lineLimit(1).fixedSize()
      }
      if let words {
        Text(verbatim: words).face(.note).foregroundStyle(Color.ink).lineLimit(6).padding(.top, 2)
      }
      if let detail = item.detail {
        Text(detail).face(.meta).foregroundStyle(Color.ink3)
      }
    }
    .accessibilityElement(children: .combine)
  }
}

extension AppModel {
  var hasActivity: Bool { me?.token.scopes.contains("activity") == true }
}

extension ActivityItem {
  var headline: String {
    // A row without a version (a deleted note's, say) reads whole without
    // one, never "Deleted from".
    func of(_ words: String, else bare: String) -> String { version.map { "\(words) \($0)" } ?? bare }
    switch kind {
    case "note.added": return of("Filed in", else: "Note filed")
    case "note.edited": return of("Edited in", else: "Note edited")
    case "note.deleted": return of("Deleted from", else: "Note deleted")
    case "note.files": return of("Files added in", else: "Files added")
    case "mail": return outcome == "filed" ? of("Reply filed in", else: "Reply filed") : "Email not filed"
    case "email.sent": return of("Email sent for", else: "Email sent")
    case "reminder": return title.map { "Reminder: \($0)" } ?? "Reminder in the daily email"
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
    case "checkin": return "Checked in at \(CheckInWords.stopName(label))"
    case "checkin.named": return "Named a check-in"
    case "checkin.deleted":
      guard all == true else { return "Deleted a check-in" }
      return count.map { "Deleted all your check-ins, \($0)" } ?? "Deleted all your check-ins"
    case "checkin.place":
      switch change {
      case "added": return "Remembered a place"
      case "spot": return "Added a spot to a remembered place"
      case "renamed": return "Renamed a remembered place"
      default: return "Forgot a remembered place"
      }
    default: return kind.replacingOccurrences(of: ".", with: " ").capitalized
    }
  }

  var isProblem: Bool {
    // A mail row's outcome is filed, not-filed or failed (WEB-APP.md).
    (kind == "mail" && outcome != "filed") || kind == "status.stopped" || kind == "connection.removed"
  }

  var time: String {
    guard let date = CheckInWords.date(at) else { return "" }
    return Calendar.current.isDateInToday(date) ? date.formatted(date: .omitted, time: .shortened) : date.formatted(.dateTime.month().day())
  }
}
