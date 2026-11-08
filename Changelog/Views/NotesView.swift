import AuthenticationServices
import ChangelogKit
import SwiftUI

/// Reading: today's notes whole, from anywhere. It opens once the token may
/// read them and, with the lock on, once Face ID says yes. Everything here is
/// held in memory, by the model or these views.
struct NotesView: View {
  @Environment(AppModel.self) private var model
  @State private var path = NavigationPath()

  var body: some View {
    NavigationStack(path: $path) {
      Group {
        if model.me == nil {
          // Offline since launch: nothing says yet what this token may do.
          Text("Notes opens once Release Notes can be reached.")
            .face(.hint)
            .foregroundStyle(Color.ink2)
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.paper)
        } else if model.readingOpen {
          NotesList()
        } else if model.readsNotes {
          LockedNotes()
        } else {
          AllowReading()
        }
      }
      .navigationTitle("Notes")
      .toolbar(.hidden, for: .navigationBar)
      .navigationDestination(for: NoteDetail.self) { NotePage(note: $0) }
      .navigationDestination(for: DayRoute.self) { DayPage(date: $0.date) }
    }
    .safeAreaInset(edge: .top) {
      if let notice = model.readingNotice {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
          Text(notice).face(.hint).foregroundStyle(Color.tangerineInk)
          Spacer(minLength: 0)
          Button("OK") { model.readingNotice = nil }.buttonStyle(QuietButtonStyle())
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(Color.paper)
        .accessibilityIdentifier("reading-notice")
      }
    }
    // Locked, or signed out: nothing stays open behind the lock, and what the
    // pages held goes with them.
    .onChange(of: model.readingOpen) { _, open in
      if !open { path = NavigationPath() }
    }
  }
}

/// The one way in for a token from before reading: no pop-up anywhere else
/// (Jamie, 2026-11-05). Release Notes asks on its own page, and everything on
/// this phone stays as it is.
private struct AllowReading: View {
  @Environment(AppModel.self) private var model
  @Environment(\.webAuthenticationSession) private var webAuthenticationSession
  @State private var problem: String?
  @State private var asking = false

  var body: some View {
    Form {
      Group {
        Section {
          VStack(alignment: .leading, spacing: 0) {
            BrandBar()
            PageTitle(title: "Notes", lede: "Read your notes here, wherever you wrote them, and change any of them.")
              .padding(.top, 22)
          }
          .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 8, trailing: 20))
          .listRowSeparator(.hidden)
        }
        Section {
          Button { allow() } label: {
            Text("Allow reading").frame(maxWidth: .infinity)
          }
          .buttonStyle(CommitButtonStyle())
          .disabled(asking)
          .listRowSeparator(.hidden)
        } footer: {
          VStack(alignment: .leading, spacing: 6) {
            SectionNote("Release Notes asks you first, and you can untick it there. This phone then gets a new token that can read, change and delete every note, so anyone holding the phone could too; Settings here can lock reading. Your reminders and anything waiting to send stay as they are.")
            if let problem { SectionNote(problem, problem: true).accessibilityIdentifier("reading-problem") }
          }
        }
      }
      .paperRows()
    }
    .paperForm()
    .overlay { if asking { ProgressView() } }
  }

  private func allow() {
    asking = true
    problem = nil
    Task {
      problem = await model.allowReading { url in
        do {
          return try await webAuthenticationSession.authenticate(
            using: url, callback: .customScheme(SignIn.callbackScheme),
            preferredBrowserSession: .shared, additionalHeaderFields: [:])
        } catch ASWebAuthenticationSessionError.canceledLogin {
          return nil
        }
      }
      asking = false
    }
  }
}

/// Reading is locked. Face ID asks as soon as this shows, once, and the button
/// is there for after a no. Only while it shows: a tab kept alive out of sight
/// must never ask on the way back to Log.
private struct LockedNotes: View {
  @Environment(AppModel.self) private var model
  @Environment(\.scenePhase) private var scenePhase
  @State private var asked = false
  @State private var showing = false

  var body: some View {
    Form {
      Group {
        Section {
          VStack(alignment: .leading, spacing: 0) {
            BrandBar()
            PageTitle(title: "Notes", lede: "Locked. You can still add notes from Log.")
              .padding(.top, 22)
          }
          .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 8, trailing: 20))
          .listRowSeparator(.hidden)
        }
        Section {
          Button { Task { await model.unlockReading() } } label: {
            Text("Unlock").frame(maxWidth: .infinity)
          }
          .buttonStyle(CommitButtonStyle())
          .listRowSeparator(.hidden)
        }
      }
      .paperRows()
    }
    .paperForm()
    .onAppear {
      showing = true
      Task { await askOnce() }
    }
    .onDisappear {
      showing = false
      asked = false
    }
    .onChange(of: scenePhase) { _, phase in
      if phase == .active { Task { await askOnce() } }
      if phase == .background { asked = false }
    }
  }

  private func askOnce() async {
    guard showing, !asked, scenePhase == .active else { return }
    asked = true
    await model.unlockReading()
  }
}

struct DayRoute: Hashable {
  let date: String
}

/// Today's notes, whole, then On this day, then the days before it, newest
/// first and a page at a time; or, once something is searched for, what was
/// found, until Clear. The lists go when this view does, so they stay in
/// memory only.
private struct NotesList: View {
  @Environment(AppModel.self) private var model
  @State private var days: [DaySummary] = []
  @State private var next: String?
  @State private var problem: String?
  @State private var past: [OnThisDay.PastDay] = []
  @State private var pastFrom: String?
  @State private var pastNext: String?
  @State private var typed = ""
  @State private var search: NoteSearch?
  @State private var found: SearchResults?
  @State private var foundNotes: [NoteDetail] = []
  @State private var foundNext: String?
  @State private var searchProblem: String?
  /// Each read of the page, and each search, numbered: an answer counts only
  /// if no read has started since it was asked for, so one that comes back
  /// late (a change and a pull both reading) can't put back what a newer read
  /// took away (Codex on #50).
  @State private var reads = 0
  @State private var searches = 0
  /// The cursor each list's next page is being read from. The cursor itself
  /// stays until a page replaces it, so a page dropped for a newer read, or
  /// a newer read that fails, leaves it there to try again (Codex on #53).
  @State private var readingNext: String?
  @State private var readingPast: String?
  @State private var readingFound: String?
  @FocusState private var searching: Bool

  /// A day's notes On this day shows; its own page has the rest.
  private static let pastNotes = 3

  var body: some View {
    List {
      Group {
        BrandBar().paperRow(top: 14, bottom: 0)
        Text("Notes").face(.title).foregroundStyle(Color.ink).accessibilityAddTraits(.isHeader).paperRow(top: 18, bottom: 0)
        SearchBox(typed: $typed, focused: $searching, showing: search != nil, find: { Task { await find() } }, clear: clear)
          .paperRow(top: 14, bottom: 0)
        if let search {
          results(for: search)
        } else {
          everyDay
        }
        Color.clear.frame(height: 24).paperRow()
      }
      .listRowSeparator(.hidden)
    }
    .paperList()
    .scrollDismissesKeyboard(.immediately)
    .refreshable {
      await model.refresh()
      await first()
    }
    .task(id: model.changes) { await first() }
  }

  /// Today, the same day in years before, and every day before it.
  @ViewBuilder private var everyDay: some View {
    Group {
      if let version = model.version {
        Text("Today in \(versionText(version))")
      } else {
        Text("Today")
      }
    }
    .face(.head)
    .foregroundStyle(Color.ink2)
    .accessibilityAddTraits(.isHeader)
    .paperRow(top: 28, bottom: 4)
    let notes = model.todayNotes.filter { !model.isBeingDeleted($0) }
    if notes.isEmpty {
      Text(emptyToday)
        .face(.hint)
        .foregroundStyle(Color.ink2)
        .paperRow(top: 8, bottom: 8)
    }
    ForEach(notes) { note in
      NavigationLink(value: note) { NoteRow(note: note) }
        .paperRow(top: 10, bottom: 10)
    }
    onThisDay
    let earlier = days.filter { $0.date != model.me?.today }
    if !earlier.isEmpty {
      Text("Earlier")
        .face(.head)
        .foregroundStyle(Color.ink2)
        .accessibilityAddTraits(.isHeader)
        .paperRow(top: 28, bottom: 4)
    }
    ForEach(earlier) { day in
      NavigationLink(value: DayRoute(date: day.date)) { DayRow(day: day) }
        .paperRow(top: 10, bottom: 10)
        .onAppear { if day.id == earlier.last?.id { Task { await more() } } }
    }
    if let problem {
      Text(problem).face(.hint).foregroundStyle(Color.tangerineInk).paperRow(top: 8, bottom: 8)
    }
  }

  /// The same day in each earlier year, as the web's Today and the morning
  /// email have it: a day's first notes, and the rest on its own page. With
  /// nothing to show, or nothing read, there is no section.
  @ViewBuilder private var onThisDay: some View {
    let shown = past.filter { !$0.notes.isEmpty }
    if !shown.isEmpty {
      Text("On this day")
        .face(.head)
        .foregroundStyle(Color.ink2)
        .accessibilityAddTraits(.isHeader)
        .paperRow(top: 28, bottom: 4)
      ForEach(shown) { day in
        NavigationLink(value: DayRoute(date: day.date)) {
          PastDayHead(day: day, from: pastFrom ?? model.me?.today ?? day.date)
        }
        .paperRow(top: 12, bottom: 2)
        ForEach(day.notes.prefix(Self.pastNotes).filter { !model.isBeingDeleted($0) }) { note in
          NavigationLink(value: note) { NoteRow(note: note) }
            .paperRow(top: 8, bottom: 8)
        }
        let left = day.notesTotal - min(day.notes.count, Self.pastNotes)
        if left > 0 {
          NavigationLink(value: DayRoute(date: day.date)) {
            Text(left == 1 ? "One more note" : "\(left) more notes").face(.action).foregroundStyle(Color.cobalt)
          }
          .paperRow(top: 0, bottom: 6)
        }
      }
      if let pastNext {
        Button("Earlier years") { Task { await morePast() } }
          .buttonStyle(QuietButtonStyle())
          .disabled(readingPast == pastNext)
          .paperRow(top: 4, bottom: 4)
      }
    }
  }

  /// What a search found, newest first, a page at a time.
  @ViewBuilder private func results(for search: NoteSearch) -> some View {
    if let found {
      Text(Self.sentence(found, for: search))
        .face(.hint)
        .foregroundStyle(Color.ink2)
        .accessibilityIdentifier("search-found")
        .paperRow(top: 18, bottom: 4)
    } else if let searchProblem {
      Text(searchProblem).face(.hint).foregroundStyle(Color.tangerineInk).paperRow(top: 18, bottom: 4)
    } else {
      ProgressView().paperRow(top: 18, bottom: 4)
    }
    let shown = foundNotes.filter { !model.isBeingDeleted($0) }
    ForEach(shown) { note in
      NavigationLink(value: note) { FoundRow(note: note) }
        .paperRow(top: 10, bottom: 10)
        .onAppear { if note.id == shown.last?.id { Task { await moreFound() } } }
    }
  }

  /// As the web's search says it.
  static func sentence(_ found: SearchResults, for search: NoteSearch) -> String {
    switch (search, found.total) {
    case (.words, 0): "No notes have all of those words."
    case (.tag(let tag), 0): "No notes have #\(tag)."
    case (_, let total): "\(total == 1 ? "1 note" : "\(total.formatted()) notes") for “\(search.shown)”, newest first"
    }
  }

  private var emptyToday: String {
    if !model.todayNotesRead { return "Today's notes couldn't be read yet. Pull down to try again." }
    return model.version.map { "No changes yet in \($0)." } ?? "Nothing yet today."
  }

  /// Everything shown, read again: the days, On this day and what's being
  /// searched for, side by side, so neither optional read holds up the days.
  /// The days are read during a search too, so Clear never shows them as they
  /// were before a note changed.
  private func first() async {
    reads += 1
    let read = reads
    let searched = Task { if let search { await find(search) } }
    let pastRead = Task { try? await model.onThisDay(before: nil) }
    let daysRead = Task { () -> Result<DayList, APIError> in
      do throws(APIError) { return .success(try await model.days(before: nil)) } catch { return .failure(error) }
    }
    // A newer read (another change, a pull) has the page.
    switch await daysRead.value {
    case .success(let page) where read == reads:
      days = page.days
      next = page.next
      problem = nil
    case .failure(let error) where read == reads:
      // What was read stays; the first read failing says so.
      if days.isEmpty { problem = error.message }
    default:
      break
    }
    // On this day never holds the page up, and a failure leaves what was there.
    if let page = await pastRead.value, read == reads {
      past = page.days
      pastFrom = page.date
      pastNext = page.next
    }
    await searched.value
  }

  private func morePast() async {
    guard let before = pastNext, readingPast != before else { return }
    let read = reads
    readingPast = before
    defer { if readingPast == before { readingPast = nil } }
    // A failure leaves the cursor to try again.
    guard let page = try? await model.onThisDay(before: before), read == reads else { return }
    past += page.days
    pastNext = page.next
  }

  /// The box's words, searched for; an empty box is the days again.
  private func find() async {
    guard let asked = NoteSearch(typed) else {
      clear()
      return
    }
    searching = false
    if asked != search {
      found = nil
      foundNotes = []
      foundNext = nil
    }
    searchProblem = nil
    search = asked
    await find(asked)
  }

  /// The first page of a search. One asked since, or Clear, wins.
  private func find(_ asked: NoteSearch) async {
    searches += 1
    let mine = searches
    do throws(APIError) {
      let page = try await model.search(asked, after: nil)
      guard search == asked, mine == searches else { return }
      found = page
      foundNotes = page.items
      foundNext = page.next
      searchProblem = nil
    } catch {
      guard search == asked, mine == searches else { return }
      if found == nil { searchProblem = error.message }
    }
  }

  private func moreFound() async {
    guard let asked = search, let after = foundNext, readingFound != after else { return }
    let mine = searches
    readingFound = after
    defer { if readingFound == after { readingFound = nil } }
    guard let page = try? await model.search(asked, after: after), search == asked, mine == searches else { return }
    foundNotes += page.items
    foundNext = page.next
  }

  private func clear() {
    typed = ""
    search = nil
    found = nil
    foundNotes = []
    foundNext = nil
    searchProblem = nil
  }

  private func more() async {
    // One read for a page, however many rows appear while it comes.
    guard let before = next, readingNext != before else { return }
    let read = reads
    readingNext = before
    defer { if readingNext == before { readingNext = nil } }
    guard let page = try? await model.days(before: before), read == reads else { return }
    days += page.days
    next = page.next
  }
}

/// The box at the top of Notes, as the web's search: words, "quoted phrases",
/// or one #tag alone for that tag's notes. A rule under it, tangerine while
/// typing, as Log's box has. The map has it too.
struct SearchBox: View {
  @Binding var typed: String
  var focused: FocusState<Bool>.Binding
  let showing: Bool
  let find: () -> Void
  let clear: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: "magnifyingglass").foregroundStyle(Color.ink3).accessibilityHidden(true)
      TextField("Search your notes", text: $typed, prompt: Text(verbatim: "cabin, \"first snow\", #lake").foregroundStyle(Color.ink3))
        .face(.note)
        .focused(focused)
        .submitLabel(.search)
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)
        .onSubmit(find)
        .accessibilityIdentifier("search")
      if showing || !typed.isEmpty {
        Button("Clear", action: clear).buttonStyle(QuietButtonStyle())
      }
    }
    .padding(.vertical, 4)
    .overlay(alignment: .bottom) {
      Rectangle()
        .fill(focused.wrappedValue ? Color.tangerine : Color.ink3)
        .frame(height: focused.wrappedValue ? 3 : 1)
    }
  }
}

/// An earlier year's day, as the web's On this day heads it: how long ago,
/// the version you were, and the date.
private struct PastDayHead: View {
  @Environment(AppModel.self) private var model
  let day: OnThisDay.PastDay
  /// The day it is looked back from.
  let from: String

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text("\(ago) you were \(versionText(day.version))").face(.line).foregroundStyle(Color.ink)
      Text(Day.label(day.date, today: model.me?.today ?? from)).face(.meta).foregroundStyle(Color.ink3)
    }
  }

  private var ago: String {
    let years = day.years(before: from)
    return years == 1 ? "A year ago" : "\(years) years ago"
  }
}

/// A note a search found: its day and version over it, since they come from
/// every year.
private struct FoundRow: View {
  @Environment(AppModel.self) private var model
  let note: NoteDetail

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(Day.label(note.date, today: model.me?.today ?? note.date)).face(.head).foregroundStyle(Color.ink2)
        if let version = note.version { versionText(version).face(.meta) }
      }
      NoteRow(note: note)
    }
  }
}

/// A past day in the list: when, what version, and how much.
private struct DayRow: View {
  @Environment(AppModel.self) private var model
  let day: DaySummary

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(Day.label(day.date, today: model.me?.today ?? day.date)).face(.line).foregroundStyle(Color.ink)
        versionText(day.version).face(.meta).foregroundStyle(Color.ink3)
      }
      Text(summary).face(.meta).foregroundStyle(Color.ink3)
    }
  }

  private var summary: String {
    var bits = [day.notesTotal == 1 ? "1 note" : "\(day.notesTotal) notes"]
    if day.files > 0 { bits.append(day.files == 1 ? "1 file" : "\(day.files) files") }
    if let place = day.place?.label ?? day.around?.label { bits.append(place) }
    if day.paused { bits.append("Paused") }
    return bits.joined(separator: " · ")
  }
}

/// One past day: where it was, its weather, and every note it has.
struct DayPage: View {
  @Environment(AppModel.self) private var model
  let date: String
  @State private var day: DayDetail?
  @State private var notes: [NoteDetail] = []
  @State private var next: String?
  @State private var problem: String?

  var body: some View {
    List {
      Group {
        if let day {
          VStack(alignment: .leading, spacing: 4) {
            versionText(day.version).face(.head).foregroundStyle(Color.ink2)
            if let place = day.place?.label ?? day.around?.label {
              Text(place).face(.meta).foregroundStyle(Color.ink3)
            }
            if let weather = day.weather {
              Text(weather.line).face(.meta).foregroundStyle(Color.ink3)
              if let credit = day.weatherCredit {
                Text(credit).face(.meta).foregroundStyle(Color.ink3)
              }
            }
            if day.paused { Text("Paused.").face(.meta).foregroundStyle(Color.ink3) }
          }
          .paperRow(top: 12, bottom: 8)
          let shown = notes.filter { !model.isBeingDeleted($0) }
          if shown.isEmpty {
            Text("No notes this day.").face(.hint).foregroundStyle(Color.ink2).paperRow(top: 8, bottom: 8)
          }
          ForEach(shown) { note in
            NavigationLink(value: note) { NoteRow(note: note) }
              .paperRow(top: 10, bottom: 10)
              .onAppear { if note.id == shown.last?.id { Task { await more() } } }
          }
        } else if let problem {
          Text(problem).face(.hint).foregroundStyle(Color.tangerineInk).paperRow(top: 12, bottom: 8)
        } else {
          ProgressView().paperRow(top: 12, bottom: 8)
        }
        Color.clear.frame(height: 24).paperRow()
      }
      .listRowSeparator(.hidden)
    }
    .paperList()
    .navigationTitle(Day.label(date, today: model.me?.today ?? date))
    .navigationBarTitleDisplayMode(.inline)
    .refreshable { await read() }
    .task(id: model.changes) { await read() }
  }

  private func read() async {
    do throws(APIError) {
      let read = try await model.day(date)
      day = read
      notes = read.notes
      next = read.next
      problem = nil
    } catch {
      if day == nil { problem = error.message }
    }
  }

  private func more() async {
    guard let after = next else { return }
    next = nil
    do throws(APIError) {
      let page = try await model.moreNotes(on: date, after: after)
      notes += page.items
      next = page.next
    } catch {
      next = after
    }
  }
}

/// A note in a list: when and how it came, its words whole, and its photos
/// small. The page has the rest.
struct NoteRow: View {
  let note: NoteDetail

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      NoteLine(note: note)
      NoteWords(note: note)
      let photos = (note.media ?? []).filter { $0.kind == "image" }
      if !photos.isEmpty {
        HStack(spacing: 6) {
          ForEach(photos.prefix(3)) { NoteThumb(file: $0, note: note).frame(width: 84, height: 84).clipped() }
          if photos.count > 3 { Text("+\(photos.count - 3)").face(.meta).foregroundStyle(Color.ink3) }
        }
      }
      let others = (note.media ?? []).filter { $0.kind != "image" }.count
      if others > 0 {
        Label(others == 1 ? "1 file" : "\(others) files", systemImage: "paperclip").face(.meta).foregroundStyle(Color.ink3)
      }
      if let place = note.place { Text(place.label).face(.meta).foregroundStyle(Color.ink3) }
    }
  }
}

/// The note's time and where it came from, as the web's note line has them.
struct NoteLine: View {
  let note: NoteDetail

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      if let time = note.time {
        Text(time).face(.time).foregroundStyle(Color.ink3).monospacedDigit().lineLimit(1).fixedSize()
      }
      Text(note.sourceName).face(.meta).foregroundStyle(Color.ink3)
    }
  }
}

extension NoteDetail {
  /// When it was written, on the clock where it was written.
  var time: String? {
    guard let writtenAt else { return nil }
    let at = (try? Date(writtenAt, strategy: .iso8601))
      ?? (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(writtenAt))
    guard let at else { return nil }
    var style = Date.FormatStyle(date: .omitted, time: .shortened)
    style.timeZone = tz.flatMap(TimeZone.init(identifier:)) ?? .current
    return at.formatted(style)
  }
}
