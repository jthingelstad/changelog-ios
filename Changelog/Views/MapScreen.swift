import ChangelogKit
import MapKit
import SwiftUI

struct MapRoute: Hashable {}

/// The map (Jamie, 2026-11-08: "map is its own thing"): where you stopped and
/// where your notes were. Check-ins and Notes each turn on and off; a year
/// narrows both; a search (words, or one #tag alone, as in Notes) keeps the
/// notes it finds; and Trails joins each kind in the order it happened. All of
/// it is read whole, as the web's Map is, and held in memory only.
///
/// It opens with reading locked, as a check-in's page does (Jamie's call 4, in
/// the design): check-ins show, and notes only once reading is open. Locking
/// lets the notes go.
struct MapScreen: View {
  @Environment(AppModel.self) private var model
  @State private var stays: [CheckIn] = []
  @State private var pins: [NotePin] = []
  @State private var filter = MapFilter()
  @State private var typed = ""
  @FocusState private var typing: Bool
  /// The keys of the notes the words found; nil until they answer.
  @State private var found: Set<String>?
  /// The words `found` answers.
  @State private var foundFor: NoteSearch?
  @State private var readingStays = false
  /// Every page of check-ins has come once.
  @State private var staysRead = false
  @State private var readingNotes = false
  /// Every page of notes has come since reading opened.
  @State private var notesRead = false
  @State private var finding = false
  @State private var problem: String?
  /// Try again counts up, and every read starts again through its own task.
  @State private var retries = 0
  @State private var chosen: MapChoice?

  var body: some View {
    let shownStays = model.hasActivity ? filter.stays(stays) : []
    let shownNotes = model.readingOpen ? filter.notes(pins, found: found) : []
    VStack(spacing: 0) {
      controls(stays: shownStays.count, notes: shownNotes.count)
      MapCanvas(checkIns: CheckInMap.pins(shownStays), spots: MapFilter.spots(shownNotes),
                stayTrail: filter.trails ? MapFilter.trail(shownStays) : [],
                noteTrail: filter.trails ? MapFilter.trail(shownNotes) : [],
                frame: frameKey) { chosen = $0 }
        .ignoresSafeArea(edges: .bottom)
    }
    .background(Color.paper)
    .navigationTitle("Map")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar(.visible, for: .navigationBar)
    .task(id: [model.checkInChanges, retries]) { await readStays() }
    // Again after a note changes, here or anywhere: an edit, a delete, one sent.
    .task(id: Reading(open: model.readingOpen, changes: model.changes, retries: retries)) { await readNotes() }
    // The words go a moment after the last key, as on the web's Map.
    .task(id: typed) {
      guard NoteSearch(typed) != filter.search else { return }
      try? await Task.sleep(for: .milliseconds(400))
      if !Task.isCancelled { filter.search = NoteSearch(typed) }
    }
    // Again as reading opens (locking let what they found go), and after a change.
    .task(id: Finding(search: filter.search, reading: Reading(open: model.readingOpen, changes: model.changes, retries: retries))) {
      await find()
    }
    .sheet(item: $chosen) { choice in
      switch choice {
      case .checkIn(let pin): CheckInPinSheet(pin: pin)
      case .notes(let spot): NoteSpotSheet(spot: spot)
      }
    }
    // A place's sheet keeps up with its stops as they are named or deleted,
    // and goes with the last of them.
    .onChange(of: stays) {
      guard case .checkIn(let pin) = chosen else { return }
      let ids = Set(pin.stays.map(\.id))
      let now = CheckInMap.pins(filter.stays(stays)).first { $0.stays.contains { ids.contains($0.id) } }
      if now != pin { chosen = now.map(MapChoice.checkIn) }
    }
    // A spot's sheet keeps up with its notes, and goes with the last of them.
    .onChange(of: pins) {
      guard case .notes(let spot) = chosen else { return }
      let now = MapFilter.spots(filter.notes(pins, found: found)).first { $0.id == spot.id }
      if now != spot { chosen = now.map(MapChoice.notes) }
    }
    // Write about this opens Log, which a sheet would stay on top of.
    .onChange(of: AppRoute.shared.newNotes) { chosen = nil }
    .onChange(of: model.readingOpen) { _, open in
      guard !open else { return }
      if case .notes = chosen { chosen = nil }
      // Its box is hidden while locked, and a search hides check-ins: let it go.
      typed = ""
      filter.search = nil
      typing = false
    }
  }

  /// The map moves to what shows when a choice changes, or what it shows first
  /// arrives; never as a stop is named or a note changes.
  private var frameKey: String {
    [String(filter.checkIns), String(filter.notes), filter.year.map(String.init) ?? "", filter.search?.shown ?? "",
     String(model.readingOpen), String(stays.isEmpty), String(staysRead), String(pins.isEmpty), String(notesRead),
     String(found == nil)].joined(separator: "|")
  }

  @ViewBuilder private func controls(stays: Int, notes: Int) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      if model.readingOpen {
        SearchBox(typed: $typed, focused: $typing, showing: filter.search != nil,
                  find: { filter.search = NoteSearch(typed) },
                  clear: { typed = ""; filter.search = nil; typing = false })
          .padding(.top, 4)
      }
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 18) {
          if model.hasActivity {
            pick("Check-ins", on: filter.checkIns) { filter.checkIns.toggle() }
          }
          if model.readsNotes {
            pick("Notes", on: model.readingOpen && filter.notes) { Task { await turnNotes() } }
          }
          yearMenu
          pick("Trails", on: filter.trails) { filter.trails.toggle() }
        }
      }
      .accessibilityElement(children: .contain)
      .accessibilityLabel("Show")
      status(stays: stays, notes: notes)
        .padding(.bottom, 8)
    }
    .padding(.horizontal, 16)
  }

  /// A choice as words, as Activity's filters: the ones on in ink over a
  /// tangerine rule, the rest in cobalt.
  private func pick(_ word: String, on: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Text(word)
        .underline(on, color: .tangerine)
        .face(on ? .tagOn : .tag)
        .foregroundStyle(on ? Color.ink : Color.cobalt)
        .frame(minHeight: 44)
        .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(on ? [.isToggle, .isSelected] : .isToggle)
    .accessibilityIdentifier("map." + word.lowercased())
  }

  private var yearMenu: some View {
    let years = MapFilter.years(model.hasActivity ? stays : [], model.readingOpen ? pins : [])
    // A year chosen stays on the menu while it has nothing.
    let listed = filter.year.map { years.contains($0) ? years : (years + [$0]).sorted(by: >) } ?? years
    let on = filter.year != nil
    return Menu {
      Picker("Year", selection: $filter.year) {
        Text("Every year").tag(Int?.none)
        ForEach(listed, id: \.self) { year in
          Text(verbatim: String(year)).tag(Int?.some(year))
        }
      }
    } label: {
      HStack(spacing: 4) {
        Text(verbatim: filter.year.map(String.init) ?? "Every year")
          .underline(on, color: .tangerine)
        Image(systemName: "chevron.down").imageScale(.small).accessibilityHidden(true)
      }
      .face(on ? .tagOn : .tag)
      .foregroundStyle(on ? Color.ink : Color.cobalt)
      .frame(minHeight: 44)
      .contentShape(.rect)
    }
    .accessibilityLabel("Year")
    .accessibilityValue(filter.year.map(String.init) ?? "Every year")
    .accessibilityIdentifier("map.year")
  }

  @ViewBuilder private func status(stays: Int, notes: Int) -> some View {
    if let problem {
      HStack(spacing: 12) {
        Text(problem).face(.hint).foregroundStyle(Color.tangerineInk)
        Button("Try again") {
          self.problem = nil
          retries += 1
        }
          .buttonStyle(QuietButtonStyle())
      }
    } else if (readingStays && self.stays.isEmpty) || (readingNotes && pins.isEmpty) {
      HStack(spacing: 8) {
        ProgressView()
        Text("Reading the map").face(.hint).foregroundStyle(Color.ink2)
      }
      .frame(minHeight: 24)
    } else if finding && found == nil {
      Text("Looking for those words").face(.hint).foregroundStyle(Color.ink2)
    } else {
      let checkInsOn = model.hasActivity && filter.checkIns && filter.search == nil
      let notesOn = model.readingOpen && filter.notes
      Text(filter.summary(stays: checkInsOn ? stays : nil, notes: notesOn ? notes : nil))
        .face(.hint)
        .foregroundStyle(Color.ink2)
        .accessibilityAddTraits(.updatesFrequently)
        .accessibilityIdentifier("map.status")
    }
  }

  /// Notes, turned on with reading locked, asks Face ID first.
  private func turnNotes() async {
    if model.readingLocked {
      await model.unlockReading()
      if model.readingOpen { filter.notes = true }
    } else {
      filter.notes.toggle()
    }
  }

  /// Every page of check-ins, in turn. The first read fills in as it goes; a
  /// later one, after a name or a delete, takes the old ones away only once it
  /// has them all.
  private func readStays() async {
    guard model.hasActivity else { return }
    readingStays = true
    problem = nil
    defer { readingStays = false }
    var read: [CheckIn] = []
    var before: String?
    do {
      repeat {
        let page = try await model.checkInPage(before: before)
        guard !Task.isCancelled else { return }
        read += page.items
        if read.count > stays.count { stays = read }
        before = page.next
      } while before != nil
      stays = read
      staysRead = true
    } catch {
      guard !Task.isCancelled else { return }
      problem = error.message
    }
  }

  /// Every note with a place of its own, while reading is open. Locked, they go.
  private func readNotes() async {
    guard model.readingOpen else {
      pins = []
      found = nil
      foundFor = nil
      notesRead = false
      return
    }
    readingNotes = true
    defer { readingNotes = false }
    var read: [NotePin] = []
    var after: String?
    do {
      repeat {
        let page = try await model.mapPins(nil, after: after)
        guard !Task.isCancelled else { return }
        read += page.pins
        if read.count > pins.count { pins = read }
        after = page.next
      } while after != nil
      pins = read
      notesRead = true
    } catch {
      guard !Task.isCancelled else { return }
      problem = error.message
    }
  }

  /// The notes with the words, found by Release Notes as the Notes tab's
  /// search finds them. A tag needs no read: each pin has its tags. What
  /// other words found goes at once, never shown under these; the same
  /// words found again, after a change, show until the new answer.
  private func find() async {
    guard case .words = filter.search, model.readingOpen, let search = filter.search else {
      found = nil
      foundFor = nil
      finding = false
      return
    }
    if foundFor != search { found = nil }
    finding = true
    // A search overtaken leaves this to the one that took its place.
    defer { if !Task.isCancelled { finding = false } }
    var keys: Set<String> = []
    var after: String?
    do {
      repeat {
        let page = try await model.mapPins(search, after: after)
        guard !Task.isCancelled else { return }
        keys.formUnion(page.pins.map(\.key))
        after = page.next
      } while after != nil
      // Only what these words found, never an answer to words since changed.
      guard !Task.isCancelled, filter.search == search else { return }
      found = keys
      foundFor = search
    } catch {
      guard !Task.isCancelled else { return }
      problem = error.message
    }
  }
}

/// What the map's notes wait on.
private struct Reading: Equatable {
  var open: Bool
  var changes: Int
  var retries: Int
}

/// What a search on the map waits on.
private struct Finding: Equatable {
  var search: NoteSearch?
  var reading: Reading
}

enum MapChoice: Identifiable {
  case checkIn(CheckInPin)
  case notes(NoteSpot)

  var id: String {
    switch self {
    case .checkIn(let pin): "c:" + pin.id
    case .notes(let spot): "n:" + spot.id
    }
  }
}

/// The notes at one spot, newest first, each opening in full.
private struct NoteSpotSheet: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  let spot: NoteSpot
  @State private var path = NavigationPath()
  @State private var detent = PresentationDetent.medium

  var body: some View {
    NavigationStack(path: $path) {
      List {
        Group {
          ForEach(spot.notes, id: \.key) { pin in
            NavigationLink(value: ActivityNote(date: pin.date, id: pin.id)) {
              VStack(alignment: .leading, spacing: 2) {
                Text(Day.label(pin.date, today: model.me?.today ?? pin.date)).face(.meta).foregroundStyle(Color.ink3)
                if pin.text.isEmpty {
                  Text("No words").face(.hint).foregroundStyle(Color.ink3)
                } else {
                  Text(pin.text).face(.note).foregroundStyle(Color.ink).lineLimit(3)
                }
              }
            }
          }
        }
        .paperRow(top: 8, bottom: 8)
      }
      .paperList()
      .navigationTitle(spot.label)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
      }
      .navigationDestination(for: ActivityNote.self) { ActivityNotePage(route: $0) }
    }
    .presentationDetents([.medium, .large], selection: $detent)
    .onChange(of: path.isEmpty) { _, empty in
      if !empty { detent = .large }
    }
  }
}

/// A place's stops, newest first, each opening its page.
private struct CheckInPinSheet: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  let pin: CheckInPin
  @State private var path = NavigationPath()
  @State private var detent = PresentationDetent.medium

  var body: some View {
    NavigationStack(path: $path) {
      List {
        Group {
          ForEach(pin.stays) { stay in
            NavigationLink(value: ActivityStop(day: stay.day, id: stay.id)) {
              Text(line(stay)).face(.hint).foregroundStyle(Color.ink)
            }
          }
        }
        .paperRow(top: 8, bottom: 8)
      }
      .paperList()
      .navigationTitle(pin.label)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
      }
      .navigationDestination(for: ActivityStop.self) { CheckInPage(day: $0.day, id: $0.id) }
    }
    // A stop's page is longer than half a screen: Write about this is below its map.
    .presentationDetents([.medium, .large], selection: $detent)
    .onChange(of: path.isEmpty) { _, empty in
      if !empty { detent = .large }
    }
  }

  private func line(_ stay: CheckIn) -> String {
    let zone = stay.timeZone.flatMap(TimeZone.init(identifier:)) ?? .current
    let date = Day.label(stay.day, today: model.me?.today ?? stay.day)
    let times = CheckInWords.stay(arrived: stay.arrived, left: stay.left, source: stay.source, timeZone: zone)
    return times.map { "\(date), \($0)" } ?? date
  }
}
