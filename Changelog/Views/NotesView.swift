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

/// Today's notes, whole, then the days before it, newest first and a page at
/// a time. The list goes when this view does, so it stays in memory only.
private struct NotesList: View {
  @Environment(AppModel.self) private var model
  @State private var days: [DaySummary] = []
  @State private var next: String?
  @State private var problem: String?

  var body: some View {
    List {
      Group {
        BrandBar()
        Text("Notes").face(.title).foregroundStyle(Color.ink).accessibilityAddTraits(.isHeader).padding(.top, 18)
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
        let past = days.filter { $0.date != model.me?.today }
        if !past.isEmpty {
          Text("Earlier")
            .face(.head)
            .foregroundStyle(Color.ink2)
            .accessibilityAddTraits(.isHeader)
            .paperRow(top: 28, bottom: 4)
        }
        ForEach(past) { day in
          NavigationLink(value: DayRoute(date: day.date)) { DayRow(day: day) }
            .paperRow(top: 10, bottom: 10)
            .onAppear { if day.id == past.last?.id { Task { await more() } } }
        }
        if let problem {
          Text(problem).face(.hint).foregroundStyle(Color.tangerineInk).paperRow(top: 8, bottom: 8)
        }
        Color.clear.frame(height: 24).paperRow()
      }
      .listRowSeparator(.hidden)
    }
    .paperList()
    .refreshable {
      await model.refresh()
      await first()
    }
    .task(id: model.changes) { await first() }
  }

  private var emptyToday: String {
    if !model.todayNotesRead { return "Today's notes couldn't be read yet. Pull down to try again." }
    return model.version.map { "No changes yet in \($0)." } ?? "Nothing yet today."
  }

  private func first() async {
    do throws(APIError) {
      let page = try await model.days(before: nil)
      days = page.days
      next = page.next
      problem = nil
    } catch {
      // What was read stays; the first read failing says so.
      if days.isEmpty { problem = error.message }
    }
  }

  private func more() async {
    guard let before = next else { return }
    // One read for a page, however many rows appear while it comes.
    next = nil
    do throws(APIError) {
      let page = try await model.days(before: before)
      days += page.days
      next = page.next
    } catch {
      next = before
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
private struct DayPage: View {
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
