import ChangelogKit
import CoreLocation
import MapKit
import SwiftUI

/// Check in now, on Log and Activity: one fix, and a `tap`. It needs only While
/// Using, so it is there whether or not the switch in Settings is on.
struct CheckInNowButton: View {
  @Environment(AppModel.self) private var model
  var trailing = false
  @State private var problem: String?

  var body: some View {
    VStack(alignment: trailing ? .trailing : .leading, spacing: 2) {
      if model.checkingIn {
        ProgressView().frame(minHeight: 28).accessibilityLabel("Finding where you are")
      } else {
        Button("Check in now") {
          problem = nil
          Task { problem = await model.checkInNow() }
        }
        .buttonStyle(QuietButtonStyle())
      }
      if let problem {
        Text(problem).face(.meta).foregroundStyle(Color.tangerineInk)
      }
    }
  }
}

/// The switch, in Settings. Off until turned on; turned on, it asks for Always,
/// once. Refused or reduced, it says so and links to iOS's Settings.
struct CheckInSection: View {
  @Environment(AppModel.self) private var model
  @Environment(\.openURL) private var openURL
  @State private var confirmDelete = false
  @State private var deleteKey = RequestKey<String>()
  @State private var deleted: String?
  @State private var problem: String?
  private let recorder = CheckInRecorder.shared

  private var notAlways: Bool { recorder.on && recorder.status != .authorizedAlways }

  var body: some View {
    Section {
      Toggle("Notice where I stop", isOn: Binding(get: { recorder.on }, set: { recorder.set(on: $0) }))
      if notAlways || (recorder.on && recorder.reduced) {
        Button("Change it in the Settings app") {
          if let settings = URL(string: UIApplication.openSettingsURLString) { openURL(settings) }
        }
      }
      if model.hasActivity {
        NavigationLink("Remembered places") { RememberedPlacesView() }
      }
      if model.me?.token.changesAll == true {
        Button("Delete all check-ins", role: .destructive) { confirmDelete = true }
      }
      if VisitsTest.hasFile {
        NavigationLink("Visits from the test") { VisitsTestPage() }
      }
    } header: {
      SectionHead("Check-ins")
    } footer: {
      SectionNote(problem ?? deleted ?? note, problem: problem != nil || notAlways)
    }
    .confirmationDialog("Delete every check-in?", isPresented: $confirmDelete, titleVisibility: .visible) {
      Button("Delete", role: .destructive) { Task { await deleteAll() } }
    } message: {
      Text("They can't be brought back. The places you remember stay.")
    }
  }

  private var note: String {
    guard recorder.on else {
      return "Adds the places you stop to Activity, to name and write about. They go to Release Notes and stay until you delete them. Changelog asks to use your location Always for this. Check in now, on Log and Activity, needs only While Using."
    }
    if notAlways {
      return "Location isn't set to Always, so Changelog can only notice a stop while it's open."
    }
    if recorder.reduced { return "Precise Location is off for Changelog, so these will be rough." }
    return "On. iOS says when you stop in its own time, often after you leave."
  }

  private func deleteAll() async {
    problem = nil
    deleted = nil
    let key = deleteKey.key(for: "all")
    do throws(APIError) {
      let count = try await model.deleteAllCheckIns(idempotencyKey: key)
      deleteKey.reset()
      deleted = count == 1 ? "Deleted 1 check-in." : "Deleted \(count) check-ins."
    } catch {
      problem = error.message
      if !error.retryable { deleteKey.reset() }
    }
  }
}

/// The places the account remembers, to rename, ignore and forget, with the
/// check-ins at each to delete. Changing them needs a token that may change
/// every note; anyone who can see them can read them. An ignored place stays
/// listed, as it is: only its check-ins hide.
struct RememberedPlacesView: View {
  /// Delete existing check-ins here, asked with the count read just before.
  struct Deleting: Identifiable {
    var place: RememberedPlace
    var count: Int
    /// The count changed since it was read, so this is the number now.
    var changed = false
    var id: String { place.id }
  }

  @Environment(AppModel.self) private var model
  @State private var places: [RememberedPlace]?
  @State private var problem: String?
  @State private var deleted: String?
  @State private var renaming: RememberedPlace?
  @State private var newName = ""
  @State private var forgetting: RememberedPlace?
  @State private var deleting: Deleting?
  @State private var nothingAt: String?
  @State private var busy = false
  @State private var saveKey = RequestKey<String>()
  @State private var deleteKey = RequestKey<String>()

  private var canChange: Bool { model.me?.token.changesAll == true }

  var body: some View {
    List {
      Group {
        if let problem {
          Text(problem).face(.hint).foregroundStyle(Color.tangerineInk)
        }
        if let deleted {
          Text(deleted).face(.hint).foregroundStyle(Color.ink2)
        }
        if let places {
          if places.isEmpty {
            Text("None yet. Open a check-in in Activity, name it, and turn on Remember this place.")
              .face(.hint)
              .foregroundStyle(Color.ink2)
          }
          ForEach(places) { place in
            row(place)
          }
          if !places.isEmpty {
            Text(canChange ? "Swipe a place to rename or forget it. Every stop there changes with it, past ones too."
                 : "To rename, ignore or forget a place from here, sign in with a token that may read and change all your notes.")
              .face(.meta)
              .foregroundStyle(Color.ink3)
          }
        } else if problem == nil {
          ProgressView()
        }
        Color.clear.frame(height: 24)
      }
      .paperRow(top: 8, bottom: 8)
      .listRowSeparator(.hidden)
    }
    .paperList()
    .navigationTitle("Remembered places")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar(.visible, for: .navigationBar)
    .task { await load() }
    .alert("Rename \(renaming?.name ?? "")", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
      TextField("Name", text: $newName)
      Button("Save") { if let place = renaming { Task { await rename(place) } } }
      Button("Cancel", role: .cancel) {}
    }
    .confirmationDialog("Forget \(forgetting?.name ?? "this place")?",
                        isPresented: Binding(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } }),
                        titleVisibility: .visible, presenting: forgetting) { place in
      Button("Forget", role: .destructive) { Task { await forget(place) } }
    } message: { place in
      Text("Its stops go back to the names they had." + (place.ignored ? " The check-ins hidden there show again." : ""))
    }
    .confirmationDialog(deleting.map { "Delete \(Self.checkIns($0.count)) at \($0.place.name)?" } ?? "",
                        isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                        titleVisibility: .visible, presenting: deleting) { asked in
      Button("Delete", role: .destructive) { Task { await deleteHere(asked) } }
    } message: { asked in
      Text((asked.changed ? "The check-ins there changed since they were counted. " : "")
           + "They can’t be brought back. \(asked.place.name) stays remembered.")
    }
    .alert(nothingAt ?? "", isPresented: Binding(get: { nothingAt != nil }, set: { if !$0 { nothingAt = nil } })) {
      Button("OK", role: .cancel) {}
    }
  }

  @ViewBuilder private func row(_ place: RememberedPlace) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      VStack(alignment: .leading, spacing: 2) {
        Text(place.name).face(.line).foregroundStyle(Color.ink)
        Text((place.spots.count == 1 ? "1 spot" : "\(place.spots.count) spots") + (place.ignored ? ", ignored" : ""))
          .face(.meta)
          .foregroundStyle(Color.ink3)
      }
      .accessibilityElement(children: .combine)
      if canChange {
        Toggle("Ignore this location", isOn: Binding(get: { place.ignored }, set: { on in Task { await ignore(place, on) } }))
          .face(.line)
          .tint(.tangerine)
          .disabled(busy)
        Text(place.ignored ? "No new check-ins are kept here, and the ones already here are hidden. Uncheck it to bring them back."
             : "Stop keeping check-ins here, and hide the ones already here. Nothing is deleted.")
          .face(.hint)
          .foregroundStyle(Color.ink2)
        Button("Delete existing check-ins here") { Task { await count(place) } }
          .buttonStyle(QuietButtonStyle(color: .tangerineInk))
          .disabled(busy)
      }
    }
    .swipeActions {
      if canChange {
        Button("Forget", role: .destructive) { forgetting = place }
        Button("Rename") {
          newName = place.name
          renaming = place
        }
      }
    }
  }

  static func checkIns(_ count: Int) -> String { count == 1 ? "1 check-in" : "\(count) check-ins" }

  private func load() async {
    do throws(APIError) {
      places = try await model.rememberedPlaces()
      problem = nil
    } catch {
      problem = error.message
    }
  }

  private func rename(_ place: RememberedPlace) async {
    let key = saveKey.key(for: place.id + "=" + newName)
    do throws(APIError) {
      try await model.rename(place, as: newName, idempotencyKey: key)
      saveKey.reset()
      await load()
    } catch {
      problem = error.message
      if !error.retryable { saveKey.reset() }
    }
  }

  private func forget(_ place: RememberedPlace) async {
    let key = saveKey.key(for: place.id)
    do throws(APIError) {
      try await model.forget(place, idempotencyKey: key)
      saveKey.reset()
      await load()
    } catch {
      problem = error.message
      if !error.retryable { saveKey.reset() }
    }
  }

  /// The switch moves at once, and back if Release Notes refuses.
  private func ignore(_ place: RememberedPlace, _ on: Bool) async {
    guard !busy, place.ignored != on else { return }
    busy = true
    defer { busy = false }
    problem = nil
    deleted = nil
    set(place.id) { $0.ignored = on }
    let key = saveKey.key(for: "\(place.id) ignored=\(on)")
    do throws(APIError) {
      let changed = try await model.setIgnored(place, on, idempotencyKey: key)
      saveKey.reset()
      set(place.id) { $0 = changed }
    } catch {
      set(place.id) { $0.ignored = place.ignored }
      problem = error.message
      if !error.retryable { saveKey.reset() }
    }
  }

  private func set(_ id: String, _ change: (inout RememberedPlace) -> Void) {
    guard let i = places?.firstIndex(where: { $0.id == id }) else { return }
    change(&places![i])
  }

  /// Delete existing check-ins here: counted first, hidden ones too, and the
  /// count shown before anything goes.
  private func count(_ place: RememberedPlace) async {
    busy = true
    defer { busy = false }
    problem = nil
    deleted = nil
    do throws(APIError) {
      let read = try await model.rememberedPlace(place.id)
      ask(read, count: read.checkIns ?? 0)
    } catch {
      problem = error.message
    }
  }

  private func ask(_ place: RememberedPlace, count: Int, changed: Bool = false) {
    if count == 0 {
      nothingAt = "There are no check-ins at \(place.name)."
    } else {
      deleting = Deleting(place: place, count: count, changed: changed)
    }
  }

  /// Gone only for the count shown. Should it have changed since, Release
  /// Notes says the count now, and this asks again with that.
  private func deleteHere(_ asked: Deleting) async {
    busy = true
    defer { busy = false }
    problem = nil
    let key = deleteKey.key(for: "\(asked.place.id) count=\(asked.count)")
    do throws(APIError) {
      let gone = try await model.deleteCheckIns(at: asked.place, count: asked.count, idempotencyKey: key)
      deleteKey.reset()
      deleted = "Deleted \(Self.checkIns(gone)) at \(asked.place.name)."
      await load()
    } catch {
      if !error.retryable { deleteKey.reset() }
      if error.code == "revision_mismatch", let now = error.count {
        ask(asked.place, count: now, changed: true)
      } else {
        problem = error.message
      }
    }
  }
}

/// One check-in: when and where it was, its name, the small map, Write about
/// this and Delete. A row has no spot, so this reads the stay as it opens, and
/// says so plainly if it has gone since. It opens with reading locked too: a
/// stop is no note.
struct CheckInPage: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  let day: String
  let id: String
  @State private var stay: CheckIn?
  @State private var gone = false
  @State private var problem: String?
  @State private var naming = false
  @State private var confirmDelete = false
  @State private var deleteKey = RequestKey<String>()
  @State private var busy = false

  var body: some View {
    List {
      Group {
        if let stay {
          loaded(stay)
        } else if gone {
          Text("That check-in isn't here any more.").face(.hint).foregroundStyle(Color.ink2)
        } else if let problem {
          Text(problem).face(.hint).foregroundStyle(Color.tangerineInk)
          Button("Try again") { Task { await read() } }
            .buttonStyle(QuietButtonStyle())
        } else {
          ProgressView()
        }
        Color.clear.frame(height: 24)
      }
      .paperRow(top: 6, bottom: 6)
      .listRowSeparator(.hidden)
    }
    .paperList()
    .navigationTitle("Check-in")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar(.visible, for: .navigationBar)
    // Again whenever one changes: a tap at the same place merges into this
    // stay, and a name form needs the revision as it is now.
    .task(id: model.checkInChanges) { await read() }
    .confirmationDialog("Delete this check-in?", isPresented: $confirmDelete, titleVisibility: .visible) {
      Button("Delete", role: .destructive) { Task { await delete() } }
    } message: {
      Text("It can't be brought back.")
    }
  }

  @ViewBuilder private func loaded(_ stay: CheckIn) -> some View {
    PageTitle(title: stay.label, lede: lede(stay))
    Text(Self.namedBy[stay.namedBy] ?? "").face(.hint).foregroundStyle(Color.ink2)
    SpotMapView(stay: stay)
    if let meta = meta(stay) {
      Text(meta).face(.meta).foregroundStyle(Color.ink3)
    }
    if let problem {
      Text(problem).face(.hint).foregroundStyle(Color.tangerineInk)
    }
    if naming {
      CheckInNameForm(stay: stay) { named in
        self.stay = named
        naming = false
      } cancel: {
        naming = false
      }
    } else {
      Button("Write about this") { Task { await model.write(about: stay) } }
        .buttonStyle(CommitButtonStyle())
      Button(stay.isNamed ? "Change the name" : "Name it") { naming = true }
        .buttonStyle(QuietButtonStyle())
      Button("Delete") { confirmDelete = true }
        .buttonStyle(QuietButtonStyle(color: .tangerineInk))
        .disabled(busy)
    }
  }

  private static let namedBy = [
    "own": "You named this stop.",
    "place": "A place you remember. Rename or forget it in Settings.",
    "district": "The neighbourhood, until you name it.",
    "none": "Nothing named this spot.",
  ]

  private func lede(_ stay: CheckIn) -> String {
    let zone = stay.timeZone.flatMap(TimeZone.init(identifier:)) ?? .current
    let date = Day.label(stay.day, today: model.me?.today ?? stay.day)
    let line = CheckInWords.stay(arrived: stay.arrived, left: stay.left, source: stay.source, timeZone: zone)
    return (line.map { "\(date), \($0)" } ?? date) + "."
  }

  private func meta(_ stay: CheckIn) -> String? {
    let sure = stay.accuracyM.map { "The circle is how sure the phone was, about \(Int($0.rounded())) m." }
    let sent = (stay.token ?? stay.client).map { "Sent by \($0)." }
    let parts = [sure, sent].compactMap(\.self)
    return parts.isEmpty ? nil : parts.joined(separator: " ")
  }

  private func read() async {
    problem = nil
    do throws(APIError) {
      stay = try await model.checkIn(day: day, id: id)
      gone = stay == nil
    } catch {
      problem = error.message
    }
  }

  private func delete() async {
    guard let stay else { return }
    busy = true
    defer { busy = false }
    problem = nil
    let key = deleteKey.key(for: stay.id)
    do throws(APIError) {
      try await model.delete(stay, idempotencyKey: key)
      deleteKey.reset()
      dismiss()
    } catch {
      problem = error.message
      if !error.retryable { deleteKey.reset() }
    }
  }
}

/// A check-in's name: this stop alone, or with Remember on, every stop there.
/// Remember is off by default, so naming one stop never relabels history
/// unasked, and shows only for a token that may change remembered places. Each
/// business nearby is a lookup Release Notes pays for, asked as this opens.
private struct CheckInNameForm: View {
  @Environment(AppModel.self) private var model
  let stay: CheckIn
  let saved: (CheckIn) -> Void
  let cancel: () -> Void
  @State private var name: String
  @State private var remember = false
  @State private var nearby: [Nearby] = []
  @State private var problem: String?
  @State private var busy = false
  @State private var saveKey = RequestKey<String>()

  init(stay: CheckIn, saved: @escaping (CheckIn) -> Void, cancel: @escaping () -> Void) {
    self.stay = stay
    self.saved = saved
    self.cancel = cancel
    _name = State(initialValue: stay.name ?? "")
  }

  private var words: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      TextField("Name", text: $name)
        .face(.writing)
        .submitLabel(.done)
        .padding(.bottom, 6)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.ink3).frame(height: 1) }
        .accessibilityLabel("Name")
      if !nearby.isEmpty {
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 14) {
            ForEach(nearby, id: \.self) { venue in
              Button(venue.name) { name = venue.name }
                .buttonStyle(QuietButtonStyle())
            }
          }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Nearby")
      }
      if model.me?.token.changesAll == true {
        Toggle("Remember this place", isOn: $remember).face(.line).tint(.tangerine)
        Text(remember ? "Every stop within about 100 m gets this name, past and future. A name you've used before gains this spot."
             : "This stop alone gets this name.")
          .face(.hint)
          .foregroundStyle(Color.ink2)
      }
      if let problem {
        Text(problem).face(.hint).foregroundStyle(Color.tangerineInk)
      }
      HStack(spacing: 18) {
        Button("Save name") { Task { await save(words, remembering: remember) } }
          .buttonStyle(CommitButtonStyle())
          .disabled(busy || words.isEmpty || words.count > 100)
        if stay.name != nil {
          Button("Take the name off") { Task { await save(nil, remembering: false) } }
            .buttonStyle(QuietButtonStyle())
            .disabled(busy)
        }
        Button("Cancel", action: cancel)
          .buttonStyle(QuietButtonStyle())
          .disabled(busy)
      }
    }
    .task {
      nearby = (try? await model.spotNames(stay))?.nearby ?? []
    }
  }

  private func save(_ value: String?, remembering: Bool) async {
    busy = true
    defer { busy = false }
    problem = nil
    let key = saveKey.key(for: "\(value ?? "")|\(remembering)")
    do throws(APIError) {
      let named: CheckIn
      if remembering, let value {
        named = try await model.remember(stay, as: value, idempotencyKey: key)
      } else {
        named = try await model.name(stay, as: value, idempotencyKey: key)
      }
      saveKey.reset()
      saved(named)
    } catch {
      problem = error.message
      if !error.retryable { saveKey.reset() }
    }
  }
}

/// The small map on a check-in's page: its spot, and a circle as sure as the
/// phone was. The app's own map of them all is phase 4.
private struct SpotMapView: View {
  let stay: CheckIn

  var body: some View {
    let center = CLLocationCoordinate2D(latitude: stay.lat, longitude: stay.lon)
    let span = max((stay.accuracyM ?? 100) * 5, 400)
    Map(initialPosition: .region(MKCoordinateRegion(center: center, latitudinalMeters: span, longitudinalMeters: span))) {
      if let accuracy = stay.accuracyM {
        MapCircle(center: center, radius: accuracy)
          .foregroundStyle(Color.cobalt.opacity(0.18))
      }
      Marker(stay.label, coordinate: center)
        .tint(Color.cobalt)
    }
    .frame(height: 200)
    .clipShape(.rect(cornerRadius: 8))
    .accessibilityLabel("Map of this check-in")
  }
}
