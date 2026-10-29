import ChangelogKit
import SwiftUI

/// Upcoming (0.3): the dates ahead, soonest first, each in the server's own
/// words ("Ada turns 36.0.0."), with add, edit and delete. Every save goes
/// at once under its own Idempotency-Key, so trying again after a lost
/// answer never makes a second date. Needs the `upcoming` scope; the app
/// never changes a token's scopes.
struct UpcomingView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.openURL) private var openURL
  @State private var list: UpcomingList?
  @State private var loadProblem: String?
  /// What the last save or delete came to, kept through the reload after.
  @State private var banner: Banner?
  @State private var editing: UpcomingTarget?
  @State private var deleting: UpcomingEntry?
  @State private var deleteKey = RequestKey<UpcomingRemoval>()

  struct Banner: Equatable {
    var text: String
    var problem = false
  }

  var body: some View {
    NavigationStack {
      List {
        if model.me == nil {
          ProgressView()
        } else if !model.canKeepUpcoming {
          Section {
            Text("This token can't keep your Upcoming dates. On the web, under Settings, API tokens, make one with “Read and change your Upcoming dates and their reminders” ticked, then sign in with it here.")
            Button("Settings on the web") { openURL(Links.settings) }
          }
        } else {
          if let banner {
            Section {
              Label(banner.text, systemImage: banner.problem ? "exclamationmark.triangle" : "checkmark.circle")
                .foregroundStyle(banner.problem ? .orange : .secondary)
            }
          }
          if let loadProblem {
            Section { Label(loadProblem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
          }
          if let list {
            Section {
              if list.entries.isEmpty {
                Text("Nothing upcoming. Add a birthday, an anniversary, a trip or an event, and the morning email reminds you.")
                  .foregroundStyle(.secondary)
              }
              ForEach(list.entries) { entry in
                Button { open(.entry(entry)) } label: { UpcomingRow(entry: entry, today: list.today) }
                  .buttonStyle(.plain)
                  .swipeActions {
                    Button("Delete", role: .destructive) { deleting = entry }
                  }
              }
            } footer: {
              if let footer = footer(list) { Text(footer) }
            }
          } else if loadProblem == nil {
            ProgressView()
          }
        }
      }
      .navigationTitle("Upcoming")
      .toolbar {
        if model.canKeepUpcoming {
          Button("Add a date", systemImage: "plus") { open(.new) }
        }
      }
      .refreshable {
        // Not read yet who this is (offline at launch): read that first.
        if model.me == nil { await model.refresh() } else { await load() }
      }
      .task(id: model.canKeepUpcoming) { await load() }
      .sheet(item: $editing) { target in
        UpcomingEditor(target: target, today: list?.today ?? model.me?.today ?? Day.string(.now)) { outcome in
          Task { await finished(outcome) }
        }
      }
      .confirmationDialog("Delete this date?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                          titleVisibility: .visible, presenting: deleting) { entry in
        Button("Delete", role: .destructive) { Task { await delete(entry) } }
      } message: { _ in
        Text("It goes from Upcoming, the morning email, your calendar and this phone's reminders.")
      }
    }
  }

  private func footer(_ list: UpcomingList) -> String? {
    var parts: [String] = []
    if list.pastLeftOut > 0 {
      parts.append(list.pastLeftOut == 1
        ? "1 past date isn't shown. It still counts toward the \(list.maxEntries) you can keep; remove it on the web."
        : "\(list.pastLeftOut) past dates aren't shown. They still count toward the \(list.maxEntries) you can keep; remove them on the web.")
    }
    if list.unreadable > 0 {
      parts.append("\(list.unreadable) more \(list.unreadable == 1 ? "date is" : "dates are") of a kind this version of Changelog can't show yet.")
    }
    return parts.isEmpty ? nil : parts.joined(separator: " ")
  }

  private func open(_ target: UpcomingTarget) {
    banner = nil
    editing = target
  }

  private func load() async {
    guard model.canKeepUpcoming else { return }
    do {
      list = try await model.upcoming()
      loadProblem = nil
    } catch {
      loadProblem = error.status == 0 ? "Couldn't reach Release Notes. Pull down to try again." : error.message
    }
  }

  private func finished(_ outcome: UpcomingOutcome) async {
    switch outcome {
    case .saved(let note): banner = note.map { Banner(text: $0) }
    case .deleted: banner = nil
    case .changedElsewhere: banner = Banner(text: Self.changedElsewhere, problem: true)
    case .removedElsewhere: banner = Banner(text: Self.removedElsewhere, problem: true)
    }
    await load()
  }

  private func delete(_ entry: UpcomingEntry) async {
    banner = nil
    let key = deleteKey.key(for: UpcomingRemoval(id: entry.id, revision: entry.revision))
    do {
      try await model.deleteUpcoming(entry, idempotencyKey: key)
      deleteKey.reset()
      list?.entries.removeAll { $0.id == entry.id }
    } catch {
      switch error.code {
      // Gone already, by this phone's lost answer or elsewhere.
      case "not_found": list?.entries.removeAll { $0.id == entry.id }
      case "revision_mismatch": banner = Banner(text: Self.changedElsewhere, problem: true)
      default: banner = Banner(text: Self.sentence(error, saving: false), problem: true)
      }
    }
    await load()
  }

  static let changedElsewhere = "That date changed somewhere else since it was read, so nothing was saved. This is the newest; open it to change it again."
  static let removedElsewhere = "That date was removed somewhere else, so nothing was saved."

  /// What to say about a refusal. Never the date's own words: the server's
  /// sentences carry none.
  static func sentence(_ error: APIError, saving: Bool) -> String {
    if error.status == 0 || (error.retryable && error.code != "rate_limited") {
      return saving
        ? "Couldn't reach Release Notes, so it may not be saved yet. Save again as it is: it won't make a second one."
        : "Couldn't reach Release Notes. Try again in a moment."
    }
    return error.upcomingSentence
  }
}

enum UpcomingTarget: Identifiable {
  case new
  case entry(UpcomingEntry)

  var id: String {
    switch self {
    case .new: "new"
    case .entry(let entry): entry.id
    }
  }

  var entry: UpcomingEntry? {
    if case .entry(let entry) = self { entry } else { nil }
  }
}

enum UpcomingOutcome {
  /// With a line to show, when the save earned a badge.
  case saved(String?)
  case deleted
  case changedElsewhere
  case removedElsewhere
}

struct UpcomingRow: View {
  let entry: UpcomingEntry
  let today: String

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(entry.line)
        .foregroundStyle(.primary)
      HStack(spacing: 6) {
        Image(systemName: UpcomingKind.icon(entry.fields.kind))
          .imageScale(.small)
          .accessibilityLabel(UpcomingKind.name(entry.fields.kind))
        Text(when)
        if let tag = entry.fields.tag { Text("#\(tag)") }
        if !entry.fields.email {
          Image(systemName: "bell.slash")
            .imageScale(.small)
            .accessibilityLabel("No reminders")
        }
      }
      .font(.caption)
      .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(.rect)
    .accessibilityElement(children: .combine)
    .accessibilityHint("Double tap to edit.")
  }

  private var when: String {
    switch entry.status {
    case "today": return "Today"
    case "ongoing": return entry.through.map { "Now, through \(Day.label($0, today: today))" } ?? "Now"
    default: return Day.label(entry.next, today: today)
    }
  }
}

/// Adds or edits one date. Checks what the phone can, finds a destination's
/// city with a dry run that saves nothing, and saves all of it at once.
struct UpcomingEditor: View {
  let target: UpcomingTarget
  let done: (UpcomingOutcome) -> Void

  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  @State private var draft: UpcomingDraft
  @State private var problem: String?
  @State private var saving = false
  @State private var saveKey = RequestKey<UpcomingBatch>()
  /// The city a dry run found for the destination typed, or why not.
  @State private var found: String?
  @State private var placeProblem: String?
  @State private var checking = false
  @State private var confirmDelete = false
  @FocusState private var placeFocused: Bool

  init(target: UpcomingTarget, today: String, done: @escaping (UpcomingOutcome) -> Void) {
    self.target = target
    self.done = done
    _draft = State(initialValue: target.entry.map { UpcomingDraft(entry: $0, today: today) } ?? UpcomingDraft(kind: .birthday, today: today))
  }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          Picker("Kind", selection: $draft.kind) {
            ForEach(UpcomingKind.allCases) { Text(UpcomingKind.name($0)).tag($0) }
          }
          .pickerStyle(.segmented)
          TextField("Title", text: $draft.title, prompt: Text(titlePrompt))
            .textInputAutocapitalization(.words)
            .submitLabel(.done)
        }

        Section {
          if draft.kind.annual {
            Picker("Month", selection: $draft.month) {
              ForEach(1...12, id: \.self) { Text(Calendar.current.monthSymbols[$0 - 1]).tag($0) }
            }
            Picker("Day", selection: $draft.day) {
              ForEach(1...UpcomingDraft.days(in: draft.month), id: \.self) { Text("\($0)").tag($0) }
            }
            TextField("Year", text: yearText, prompt: Text(draft.kind == .birthday ? "Year born, if you know it" : "First year, if you know it"))
              .keyboardType(.numberPad)
          } else {
            DatePicker(draft.kind == .trip ? "First day" : "Day", selection: day(\.start), displayedComponents: .date)
            if draft.kind == .trip {
              DatePicker("Last day", selection: day(\.end), in: (Day.date(draft.start) ?? .distantPast)..., displayedComponents: .date)
            }
          }
        } header: {
          Text("When")
        } footer: {
          if draft.kind.annual {
            Text(draft.kind == .birthday ? "With the year, the line says which version it turns." : "With the year, the line says how many years.")
          }
        }

        if !draft.kind.annual {
          Section {
            HStack {
              TextField(draft.kind == .trip ? "Destination" : "Where", text: $draft.place,
                        prompt: Text(draft.kind == .trip ? "Like Zürich, or Paris, Texas" : "Where, if you like"))
                .focused($placeFocused)
                .submitLabel(.search)
                .onSubmit { Task { await checkPlace() } }
              if checking {
                ProgressView()
              } else {
                Button("Find") { Task { await checkPlace() } }
                  .disabled(draft.place.trimmingCharacters(in: .whitespaces).isEmpty)
              }
            }
          } header: {
            Text(draft.kind == .trip ? "Destination" : "Place")
          } footer: {
            if let placeProblem {
              Text(placeProblem).foregroundStyle(.orange)
            } else if let found {
              Text(found)
            } else {
              Text("A city the city search knows. Find shows which one, and saves nothing.")
            }
          }
        }

        Section {
          TextField("Tag", text: $draft.tag, prompt: Text("Like family"))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        } footer: {
          Text("One tag, to group it with other dates.")
        }

        Section {
          Toggle("In the morning email", isOn: $draft.email)
          if draft.email {
            NavigationLink {
              ReminderDaysView(days: $draft.reminders)
            } label: {
              LabeledContent("Remind me", value: ReminderDaysView.summary(draft.reminders))
            }
          }
        } footer: {
          Text(draft.email
            ? "Reminders come in the morning email, and on this phone when Upcoming reminders are on in Settings."
            : "It stays here, with no reminders in the email or on this phone.")
        }

        if let problem {
          Section { Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
        }

        if target.entry != nil {
          Section {
            Button("Delete this date", role: .destructive) { confirmDelete = true }
              .disabled(saving)
          }
        }
      }
      .navigationTitle(target.entry == nil ? "Add a date" : "Edit")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          if saving {
            ProgressView()
          } else {
            Button("Save") { Task { await save() } }
              .disabled(draft.title.trimmingCharacters(in: .whitespaces).isEmpty)
          }
        }
      }
      .interactiveDismissDisabled(saving)
      .onChange(of: draft.place) {
        found = nil
        placeProblem = nil
      }
      .onChange(of: placeFocused) { _, focused in
        // Leaving the box looks the city up, once per thing typed.
        if !focused, found == nil, placeProblem == nil, !draft.place.trimmingCharacters(in: .whitespaces).isEmpty {
          Task { await checkPlace() }
        }
      }
      .confirmationDialog("Delete this date?", isPresented: $confirmDelete, titleVisibility: .visible) {
        Button("Delete", role: .destructive) { Task { await delete() } }
      } message: {
        Text("It goes from Upcoming, the morning email, your calendar and this phone's reminders.")
      }
    }
  }

  private var titlePrompt: String {
    switch draft.kind {
    case .birthday: "Whose birthday"
    case .anniversary: "Whose anniversary"
    case .trip: "Like Lake week"
    case .event: "Like the school play"
    }
  }

  private var yearText: Binding<String> {
    Binding(
      get: { draft.year.map(String.init) ?? "" },
      set: { draft.year = Int(String($0.filter(\.isNumber).prefix(4))) })
  }

  private func day(_ path: WritableKeyPath<UpcomingDraft, String>) -> Binding<Date> {
    Binding(
      get: { Day.date(draft[keyPath: path]) ?? .now },
      set: { draft[keyPath: path] = Day.string($0) })
  }

  /// A dry run: the server finds the city, and nothing is saved.
  private func checkPlace() async {
    let asked = draft.place
    guard !asked.trimmingCharacters(in: .whitespaces).isEmpty, !checking else { return }
    switch draft.placeCheck(editing: target.entry) {
    case .failure(let problem):
      placeProblem = problem.rawValue
    case .success(let batch):
      checking = true
      defer { checking = false }
      do {
        let answer = try await model.saveUpcoming(batch, idempotencyKey: nil)
        guard draft.place == asked else { return }
        found = answer.saved?.fields.place.map { "Found \($0)." } ?? "Found it."
      } catch {
        guard draft.place == asked else { return }
        placeProblem = error.status == 0 ? "Couldn't reach Release Notes to look it up." : error.upcomingSentence
      }
    }
  }

  private func save() async {
    problem = nil
    switch draft.batch(editing: target.entry) {
    case .failure(let problem):
      self.problem = problem.rawValue
    case .success(let batch):
      saving = true
      defer { saving = false }
      do {
        let saved = try await model.saveUpcoming(batch, idempotencyKey: saveKey.key(for: batch))
        saveKey.reset()
        let badges = (saved.unlocked ?? []).map(\.name)
        done(.saved(badges.isEmpty ? nil : "Unlocked: \(badges.joined(separator: ", "))"))
        dismiss()
      } catch {
        switch error.code {
        case "revision_mismatch":
          done(.changedElsewhere)
          dismiss()
        case "not_found" where target.entry != nil:
          done(.removedElsewhere)
          dismiss()
        default:
          problem = UpcomingView.sentence(error, saving: true)
        }
      }
    }
  }

  private func delete() async {
    guard let entry = target.entry else { return }
    saving = true
    defer { saving = false }
    do {
      try await model.deleteUpcoming(entry, idempotencyKey: saveKey.key(for: .removing(entry)))
      done(.deleted)
      dismiss()
    } catch {
      switch error.code {
      case "not_found":
        done(.deleted)
        dismiss()
      case "revision_mismatch":
        done(.changedElsewhere)
        dismiss()
      default:
        problem = UpcomingView.sentence(error, saving: false)
      }
    }
  }
}

/// The days before a date to remind: up to six, at least one.
struct ReminderDaysView: View {
  @Binding var days: [Int]
  static let choices = [0, 1, 2, 3, 7, 14, 30, 60, 90]

  var body: some View {
    Form {
      Section {
        ForEach(Array(Set(Self.choices + days)).sorted(), id: \.self) { n in
          let on = days.contains(n)
          Toggle(Self.name(n).capitalizedFirst, isOn: Binding(
            get: { days.contains(n) },
            set: { wanted in
              if wanted { days = Array(Set(days + [n])).sorted(by: >) } else { days.removeAll { $0 == n } }
            }))
            .disabled(on ? days.count == 1 : days.count >= 6)
        }
      } footer: {
        Text("Up to six. For none, turn the morning email off for this date.")
      }
    }
    .navigationTitle("Remind me")
  }

  static func name(_ n: Int) -> String {
    switch n {
    case 0: "on the day"
    case 1: "the day before"
    case 7: "a week before"
    case 14: "two weeks before"
    default: "\(n) days before"
    }
  }

  static func summary(_ days: [Int]) -> String {
    days.sorted(by: >).map(name).formatted(.list(type: .and)).capitalizedFirst
  }
}

extension UpcomingKind {
  static func name(_ kind: UpcomingKind) -> String {
    switch kind {
    case .birthday: "Birthday"
    case .anniversary: "Anniversary"
    case .trip: "Trip"
    case .event: "Event"
    }
  }

  static func icon(_ kind: UpcomingKind) -> String {
    switch kind {
    case .birthday: "gift"
    case .anniversary: "heart"
    case .trip: "airplane"
    case .event: "star"
    }
  }
}

/// Days as the API writes them, `YYYY-MM-DD`, read and written in this
/// phone's calendar, so the day picked is the day sent.
enum Day {
  static func date(_ day: String) -> Date? {
    guard let (y, m, d) = UpcomingDraft.parse(day) else { return nil }
    return Calendar.current.date(from: DateComponents(year: y, month: m, day: d, hour: 12))
  }

  static func string(_ date: Date) -> String {
    let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
  }

  /// "Wed, Nov 4", with the year when it isn't this one.
  static func label(_ day: String, today: String) -> String {
    guard let date = date(day) else { return day }
    let sameYear = day.prefix(4) == today.prefix(4)
    return sameYear
      ? date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
      : date.formatted(.dateTime.month(.abbreviated).day().year())
  }
}

extension String {
  var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
