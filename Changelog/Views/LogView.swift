import ChangelogKit
import PhotosUI
import SwiftUI

/// The home screen: today's version, the box, the tag row, Commit, and what
/// happened today from every channel.
struct LogView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dynamicTypeSize) private var typeSize
  @FocusState private var typing: Bool
  @State private var editing: ActivityItem?
  @State private var fixing: OutboxItem?
  /// The note a swipe asked to delete, waiting for the confirmation.
  @State private var deleting: ActivityItem?
  /// A held note whose Delete was tapped, waiting for the confirmation.
  @State private var discarding: OutboxItem?

  var body: some View {
    @Bindable var model = model
    NavigationStack {
      // The web's Today page on the phone: the date, the version, the box
      // and Commit, then what happened today, all on the paper.
      ScrollViewReader { list in List {
        Group {
          BrandBar { Streak() }
          VersionHeader()
            .padding(.top, 18)
          Text("What changed today?")
            .face(.section)
            .accessibilityAddTraits(.isHeader)
            .padding(.top, 26)
          TextField("Note", text: $model.draft, prompt: Text("A few words, a photo, a voice memo…").foregroundStyle(Color.ink3),
                    axis: .vertical)
            .face(.writing)
            .lineLimit(3...10)
            .focused($typing)
            .submitLabel(.return)
            .padding(.top, 6).padding(.bottom, 12)
            // A rule under the box, thicker and tangerine while typing.
            .overlay(alignment: .bottom) {
              Rectangle()
                .fill(typing ? Color.tangerine : Color.ink3)
                .frame(height: typing ? 3 : 1)
            }
            .accessibilityLabel("Note")
          if !model.draftFiles.isEmpty { AttachmentStrip().padding(.top, 10) }
          // What a moment left out: for the person, never the note.
          if let notice = model.momentNotice {
            Label(notice, systemImage: "info.circle").face(.meta).foregroundStyle(Color.ink3)
          }
          TagRowView()
          if model.day != nil { DayMenu() }
          if model.placeLabel != nil || model.sticky != nil {
            HStack {
              PlaceMenu()
              Spacer()
              if let sticky = model.sticky {
                Label("#\(sticky) on every note", systemImage: "pin.fill")
                  .face(.meta)
                  .foregroundStyle(Color.ink3)
              }
            }
          }
          // At accessibility sizes Commit goes under the buttons, whole,
          // rather than squeezed beside them into "Com-mit".
          let row = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading)) : AnyLayout(HStackLayout())
          row {
            ComposerTools()
            if !typeSize.isAccessibilitySize { Spacer() }
            Button("Commit") {
              Task {
                await model.commit()
                // A tall draft (a moment's, with its day and place) shrinks
                // to an empty box, and the list would keep its place, down in
                // Today with the box gone above. Back to the box, with Commit
                // just above the keyboard, or the top when it all fits.
                withAnimation { list.scrollTo(Self.composer, anchor: .bottom) }
              }
            }
            .lineLimit(1)
            .buttonStyle(CommitButtonStyle())
            .disabled(!model.canCommit)
            .keyboardShortcut(.return, modifiers: .command)
          }
          .id(Self.composer)
        }
        .paperRow()

        if let problem = model.problem {
          Label(problem, systemImage: "exclamationmark.triangle")
            .face(.hint)
            .foregroundStyle(Color.tangerineInk)
            .paperRow(top: 16)
        }

        if !model.waiting.isEmpty {
          Text("Waiting to send")
            .face(.head)
            .foregroundStyle(Color.ink2)
            .accessibilityAddTraits(.isHeader)
            .paperRow(top: 28, bottom: 4)
          ForEach(model.waiting) { item in
            if model.isHeld(item) {
              // Written under another account: nothing goes until the
              // owner chooses (Jamie, 2026-10-30).
              HeldRow(item: item) { discarding = item }
                .paperRow(top: 8, bottom: 8)
            } else {
              WaitingRow(item: item)
                .paperRow(top: 8, bottom: 8)
                .swipeActions {
                  Button("Discard", role: .destructive) { Task { await model.discard(item) } }
                  if item.refusal != nil && (item.isNote || item.isEdit) { Button("Fix") { fixing = item } }
                }
            }
          }
        }

        HStack(alignment: .firstTextBaseline) {
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
          Spacer()
          CheckInNowButton(trailing: true)
        }
        .paperRow(top: 28, bottom: 4)
        if model.today.isEmpty {
          Text(model.version.map { "No changes yet in \($0)." } ?? "Nothing yet today.")
            .face(.hint)
            .foregroundStyle(Color.ink2)
            .paperRow(top: 8, bottom: 8)
        }
        ForEach(model.today) { item in
          ActivityRow(item: item, words: model.words(of: item))
            .paperRow(top: 8, bottom: 8)
            .swipeActions {
              if model.canChange(item) {
                Button("Delete", role: .destructive) { deleting = item }
                Button("Edit") { editing = item }
              }
            }
        }
        // Room to scroll the last row clear of the tab bar.
        Color.clear.frame(height: 24).paperRow()
      } }
      .paperList()
      .navigationTitle("Changelog")
      .toolbar(.hidden, for: .navigationBar)
      .refreshable { await model.refresh() }
      // The box takes the keyboard as Log opens, and the keyboard covers the
      // tabs: scrolling puts it away.
      .scrollDismissesKeyboard(.immediately)
      .onAppear { typing = true }
      // A shortcut, a control or a widget asked for a new note while Log was
      // already open.
      .onChange(of: AppRoute.shared.newNotes) { typing = true }
      .onChange(of: model.draft) { before, now in
        if before.isEmpty, !now.isEmpty { Task { await model.draftStarted() } }
      }
      .overlay(alignment: .bottom) { Toast() }
      .sheet(item: $editing) { item in EditNoteView(item: item) }
      // Locked: an editor or a question open on a note from elsewhere closes
      // with the rest of reading. This token's own notes stay, as they always have.
      .onChange(of: model.readingOpen) { _, open in
        guard !open else { return }
        if let item = editing, !model.isMine(item) { editing = nil }
        if let item = deleting, !model.isMine(item) { deleting = nil }
      }
      // Jamie, 2026-10-30: a swipe asks before a note goes for good.
      .confirmationDialog("Delete this note?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                          titleVisibility: .visible, presenting: deleting) { item in
        Button("Delete", role: .destructive) { Task { await model.delete(item) } }
      } message: { item in
        Text(item.via == "email" ? "It goes from Release Notes, with its photos and files and the email it came in. This can't be undone."
             : "It goes from Release Notes, with its photos and files. This can't be undone.")
      }
      // A held note's Delete asks first too.
      .confirmationDialog(discarding?.isCheckIn == true ? "Delete this check-in?"
                            : discarding?.isNote == false ? "Delete this change?" : "Delete this note?",
                          isPresented: Binding(get: { discarding != nil }, set: { if !$0 { discarding = nil } }),
                          titleVisibility: .visible, presenting: discarding) { item in
        Button("Delete", role: .destructive) { Task { await model.discard(item) } }
      } message: { item in
        Text(item.files.isEmpty ? "It goes from this phone and is never sent. This can't be undone."
             : "It goes from this phone with its files and is never sent. This can't be undone.")
      }
      .sheet(item: $fixing) { item in
        // A refused edit opens with its words, to save from the newest
        // revision; a refused note, to send again.
        if case .edit(let date, let id, _, _) = item.operation {
          EditNoteView(date: date, id: id, title: "Fix and save", refused: item)
        } else {
          FixWaitingView(item: item)
        }
      }
    }
  }

  /// The row with Commit, which a commit scrolls back to.
  private static let composer = "composer"
}

/// The day as the web's Today page sets it: the date in small mono
/// capitals, the version large, the version that ships next, and the week
/// and day lived.
struct VersionHeader: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if let today = model.me.flatMap({ Day.date($0.today) }) {
        Text(today.formatted(.dateTime.weekday(.wide).month(.wide).day()))
          .textCase(.uppercase)
          .face(.dateline)
          .foregroundStyle(Color.ink2)
      }
      // A version is never broken or cut off: on one line, and smaller
      // before it would be too wide for the row.
      Text(model.version ?? "…")
        .face(.display)
        .monospacedDigit()
        .foregroundStyle(Color.ink)
        .lineLimit(1)
        .minimumScaleFactor(0.5)
        .padding(.top, 8)
        .accessibilityLabel(model.version.map { "Version \($0)" } ?? "Version loading")
      if let next {
        Text("\(versionText(next.version)) ships \(next.on).")
          .face(.hint)
          .foregroundStyle(Color.ink2)
          .padding(.top, 12)
      }
      // The line under "ships" on the web's Today. Jamie, 2026-11-01: "it
      // should also be on the big version just like the website."
      if let lived = model.me?.lived {
        Text(lived.text)
          .face(.hint)
          .foregroundStyle(Color.ink2)
          .padding(.top, next == nil ? 12 : 2)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  /// Tomorrow's version, from the server's `days`, never worked out here.
  private var next: (version: String, on: String)? {
    guard let me = model.me, let today = Day.date(me.today),
          let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: today),
          let version = me.version(on: Day.string(tomorrow)) else { return nil }
    return (version, tomorrow.formatted(.dateTime.month(.wide).day()))
  }
}

/// The streak, or that the email stopped, at the end of Log's bar.
struct Streak: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    if let me = model.me {
      if me.status == "stopped" {
        Text("Email stopped").face(.head).foregroundStyle(Color.tangerineInk)
      } else if me.streak > 1 {
        Text("\(me.streak)-day streak").face(.head).foregroundStyle(Color.ink2)
      }
    }
  }
}

struct WaitingRow: View {
  @Environment(AppModel.self) private var model
  let item: OutboxItem
  /// Why it is held, in place of its status: written under another account.
  var held: String? = nil

  private var summary: String {
    switch item.operation {
    case .note(let text, _, _): text
    // An edit holds a note's whole words, and nothing here says whose note.
    case .edit(_, _, let text, _): model.readingLocked ? "An edit to a note" : "Edit: \(text)"
    case .delete(let date, _): "Delete a note from \(date)"
    case .attach(let attach): "Add \(Self.count(attach.files)) to a note from \(attach.date)"
    case .removeFile(let date, _, _): "Take a file off a note from \(date)"
    case .pins(let pinned): pinned.isEmpty ? "Unpin every tag" : "Pin " + pinned.map { "#\($0)" }.joined(separator: " ")
    case .post(let post):
      post.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Self.count(post.files) : post.text
    // Never the spot.
    case .checkIn(let stop):
      CheckInWords.stay(arrived: stop.arrived, left: stop.left, source: stop.source,
                        timeZone: stop.timeZone.flatMap(TimeZone.init(identifier:)) ?? .current)
        .map { "Check-in: \($0)" } ?? "Check-in"
    }
  }

  /// What rides with a note besides its words.
  private var extras: String? {
    guard case .post(let post) = item.operation else { return nil }
    let parts = [post.files.isEmpty ? nil : Self.count(post.files), post.place?.label ?? (post.spot == nil ? nil : "Here")]
    let said = parts.compactMap(\.self)
    return said.isEmpty ? nil : said.joined(separator: " · ")
  }

  static func count(_ files: [QueuedFile]) -> String {
    let photos = files.filter(\.isPhoto).count
    let memos = files.filter(\.isRecording).count
    let others = files.count - photos - memos
    return [
      photos == 0 ? nil : photos == 1 ? "1 photo" : "\(photos) photos",
      memos == 0 ? nil : memos == 1 ? "1 voice memo" : "\(memos) voice memos",
      others == 0 ? nil : others == 1 ? "1 file" : "\(others) files",
    ].compactMap(\.self).joined(separator: ", ")
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      if let held {
        Text(held).face(.meta).foregroundStyle(Color.tangerineInk).accessibilityIdentifier("held")
      } else if let refusal = item.refusal {
        Text(refusal).face(.meta).foregroundStyle(Color.tangerineInk)
      } else {
        Text(item.status).face(.meta).foregroundStyle(Color.ink3)
      }
      // Faded while it waits, as the web shows a note still saving; a note
      // refused or held waits on its owner, not the network.
      Text(summary).face(.note).lineLimit(2).opacity(item.refusal == nil && held == nil ? 0.6 : 1)
      if let extras {
        Label(extras, systemImage: "paperclip").face(.meta).foregroundStyle(Color.ink3)
      }
    }
  }
}

/// A write held because it was written under another account than the one
/// signed in now, or before signing in, with the owner's two choices: send
/// it to this account, or delete it, which asks first. Nothing held goes
/// without the first.
struct HeldRow: View {
  @Environment(AppModel.self) private var model
  let item: OutboxItem
  let delete: () -> Void

  /// The plain line: whose it was, and for an edit or a delete, why it
  /// can go only from there.
  static func line(_ item: OutboxItem) -> String {
    let whose = item.account == nil
      ? "Written before you signed in, perhaps to another account."
      : "Written while signed in to another account."
    return item.canMove ? whose : whose + " It changes a note there, so it can go only from that account."
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      WaitingRow(item: item, held: Self.line(item))
      // Two quiet actions, each its own button rather than the row's:
      // cobalt to send, the refusal's tangerine ink to delete.
      HStack(spacing: 24) {
        if item.canMove {
          Button("Send to this account") { Task { await model.sendHere(item) } }
            .buttonStyle(QuietButtonStyle())
        }
        Button("Delete", role: .destructive, action: delete)
          .buttonStyle(QuietButtonStyle(color: .tangerineInk))
      }
    }
  }
}

struct Toast: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    if let toast = model.toast {
      // Ink on paper turned over: the one dark mark on a light screen.
      Text(toast)
        .face(.stamp)
        .foregroundStyle(Color.paper)
        .padding(.horizontal, 18).padding(.vertical, 11)
        .background(Color.ink, in: .capsule)
        .padding(.bottom, 12)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .task {
          // Log and Activity each have one. Cancelled is a tab that isn't on
          // the screen, and that one mustn't take the toast off the other.
          guard (try? await Task.sleep(for: .seconds(2.5))) != nil else { return }
          withAnimation { model.clearToast() }
        }
        .accessibilityAddTraits(.updatesFrequently)
        .accessibilityIdentifier("toast")
    }
  }
}

/// Edits a note this token wrote, from the revision it read. An edit
/// Release Notes refused (changed since it was read, or too long) opens here
/// too, with its own words, and saves from the revision read now.
struct EditNoteView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  let date: String
  let id: String
  let title: String
  let refused: OutboxItem?
  @State private var note: NoteDetail?
  @State private var failure: APIError?
  @State private var text: String
  @State private var saving = false
  /// Photos, a camera shot or a recording still coming in: Save waits, so
  /// the change goes with every file picked (Codex on #51).
  @State private var importing = 0
  @State private var lockedOut = false
  /// The files an edit takes off, by number, and the new ones it puts on,
  /// kept in the queue's folder until it is saved or cancelled.
  @State private var removing: Set<Int> = []
  @State private var adding: [QueuedFile] = []
  @State private var thumbnails: [UUID: CGImage] = [:]
  @State private var confirming = false
  @State private var kept: EditFilesKept?

  /// Locked, the words of a note from elsewhere stay closed: what it says now,
  /// and a refused edit's own, which are that note's too.
  private var closed: Bool { model.readingLocked && note?.mine != true }

  init(item: ActivityItem) {
    self.init(date: item.day ?? "", id: item.note ?? "", title: item.version.map { "Edit in \($0)" } ?? "Edit")
  }

  init(date: String, id: String, title: String, refused: OutboxItem? = nil) {
    self.date = date
    self.id = id
    self.title = title
    self.refused = refused
    _text = State(initialValue: refused?.text ?? "")
  }

  var body: some View {
    NavigationStack {
      Form {
        Group {
          if let refusal = refused?.refusal {
            Section {
              Text(refusal).foregroundStyle(Color.tangerineInk)
            } footer: {
              if !closed { SectionNote("Your words are below. Saving puts them in place of what the note says now.") }
            }
          }
          if let failure {
            Section {
              Label(Self.sentence(failure), systemImage: "exclamationmark.triangle").foregroundStyle(Color.tangerineInk)
              if failure.retryable { Button("Try again") { Task { await read() } } }
            }
          }
          if lockedOut {
            Section {
              Label("This note came from somewhere else, so it stays closed while Notes is locked. Unlock Notes, then come back to it.",
                    systemImage: "lock")
                .foregroundStyle(Color.ink2)
            }
          } else if !closed, note != nil || refused != nil {
            Section {
              TextField("Note", text: $text, axis: .vertical).lineLimit(3...20)
            } footer: {
              if let change, change.words != nil, let refusal = change.refusal { SectionNote(refusal) }
            }
            if let note, refused == nil, model.canAddFiles {
              EditFiles(note: note, removing: $removing, adding: $adding, thumbnails: $thumbnails,
                        importing: $importing, refusal: change?.words == nil ? change?.refusal : nil)
            }
          } else if failure == nil {
            ProgressView()
          }
          if refused != nil, !closed {
            Section { CopyWordsButton(text: text) }
            if let note {
              Section {
                Text(verbatim: note.text).foregroundStyle(Color.ink2).textSelection(.enabled)
              } header: {
                SectionHead("What it says now")
              }
            }
          }
        }
        .paperRows()
      }
      .paperForm()
      // Saving, until the change is queued: nothing on the sheet may take
      // off a file the change goes with, or close it (Codex on #51).
      .disabled(saving)
      .interactiveDismissDisabled(saving)
      .navigationTitle(title)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save") {
            // Files taken off go for good: asked first.
            if refused == nil, !removing.isEmpty { confirming = true } else { save() }
          }
          .disabled(!canSave)
        }
      }
      .confirmationDialog(removing.count == 1 ? "Take this file off the note?" : "Take \(removing.count) files off the note?",
                          isPresented: $confirming, titleVisibility: .visible) {
        Button(removing.count == 1 ? "Take It Off" : "Take Them Off", role: .destructive) { save() }
      } message: {
        Text(note?.source == "email"
             ? "Each goes with its transcript or description. A file that came by email stays in that email. This can't be undone."
             : "Each goes with its transcript or description. This can't be undone.")
      }
      .task {
        if kept == nil { kept = model.editFiles() }
        // Once: back from the camera, the words typed stay.
        if note == nil, !lockedOut { await read() }
      }
      .onChange(of: adding) { _, files in kept?.files = files }
      // Locked with this open: gone with the rest of reading, unless it's
      // this token's own note, which stays as it always has.
      .onChange(of: model.readingLocked) { _, locked in
        if locked, note?.mine != true { dismiss() }
      }
    }
  }

  /// The edit as it stands, from the note read.
  private var change: NoteChange? {
    note.map { NoteChange($0, words: text, adding: adding, removing: removing) }
  }

  private var canSave: Bool {
    guard note != nil, !saving, importing == 0 else { return false }
    // A refused edit saves its words from the newest revision, as ever.
    if refused != nil { return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    guard let change else { return false }
    return !change.isEmpty && change.refusal == nil
  }

  private func save() {
    guard let note else { return }
    saving = true
    Task {
      if let refused {
        if await model.retry(refused, text: text, revision: note.revision) { dismiss() }
      } else if let change {
        // Queued, the change holds the new files and the sheet closes while
        // it goes, so nothing here can take them off under it.
        _ = await model.change(change) {
          kept?.saved = true
          dismiss()
        }
      }
      saving = false
    }
  }

  private func read() async {
    failure = nil
    do {
      let read = try await model.load(date: date, id: id)
      guard !model.readingLocked || read.mine == true else {
        lockedOut = true
        return
      }
      note = read
      if refused == nil { text = read.text }
    } catch {
      failure = error
    }
  }

  /// Why the note couldn't be read for editing, and what to do.
  static func sentence(_ error: APIError) -> String {
    switch error.code {
    case "not_yours": "Another token sent this note, so this phone can't change it. Change it on the web."
    case "not_found": "This note is gone: it was deleted somewhere else."
    default:
      error.signedOut ? "Sign in again to change this note."
        : error.status == 0 ? "Couldn't reach Release Notes to read this note. Try again in a moment." : error.message
    }
  }
}

/// The new files an edit holds in the queue's folder. Saved, they belong to
/// the queued change; otherwise they go when the edit does, closed in any
/// way (Cancel, a swipe, reading locking), and never while it is only covered
/// by the camera.
final class EditFilesKept {
  private let outbox: Outbox
  var files: [QueuedFile] = []
  var saved = false

  init(outbox: Outbox) {
    self.outbox = outbox
  }

  deinit {
    if !saved { outbox.removeFiles(files) }
  }
}

/// A note's files as an edit changes them: each it has, to take off or keep,
/// and new ones to put on from Photos, the camera or the recorder. Nothing
/// changes until the edit is saved.
private struct EditFiles: View {
  @Environment(AppModel.self) private var model
  let note: NoteDetail
  @Binding var removing: Set<Int>
  @Binding var adding: [QueuedFile]
  @Binding var thumbnails: [UUID: CGImage]
  /// How many imports are still coming in.
  @Binding var importing: Int
  /// Why Release Notes would refuse the files as they stand.
  let refusal: String?
  @State private var picks: [PhotosPickerItem] = []
  @State private var camera = false
  @State private var recording = false
  @State private var problem: String?

  private var files: [NoteFileEntry] { note.media ?? [] }
  private var room: Int { MediaType.maxFiles - (files.count - removing.count + adding.count) }

  var body: some View {
    Section {
      ForEach(files) { file in
        let off = removing.contains(file.n)
        HStack(spacing: 12) {
          Group {
            if file.kind == "image" {
              NoteThumb(file: file, note: note)
            } else {
              Self.icon(file.kind == "audio" ? "waveform" : "doc")
            }
          }
          .frame(width: 44, height: 44)
          .opacity(off ? 0.4 : 1)
          Text(Self.name(file))
            .strikethrough(off)
            .foregroundStyle(off ? Color.ink3 : Color.ink)
            .lineLimit(1)
          Spacer(minLength: 8)
          Button(off ? "Keep" : "Take off") {
            if off { removing.remove(file.n) } else { removing.insert(file.n) }
          }
          .buttonStyle(QuietButtonStyle(color: off ? .cobalt : .tangerineInk))
          .accessibilityLabel(off ? "Keep \(Self.name(file))" : "Take off \(Self.name(file))")
        }
        .accessibilityElement(children: .contain)
      }
      ForEach(adding) { file in
        HStack(spacing: 12) {
          Group {
            if let thumbnail = thumbnails[file.id] {
              Image(decorative: thumbnail, scale: 1).resizable().scaledToFill()
            } else {
              Self.icon(file.isRecording ? "waveform" : "doc")
            }
          }
          .frame(width: 44, height: 44)
          .clipShape(.rect(cornerRadius: 6))
          VStack(alignment: .leading, spacing: 0) {
            Text(file.name).foregroundStyle(Color.ink).lineLimit(1)
            Text("New").face(.meta).foregroundStyle(Color.ink3)
          }
          Spacer(minLength: 8)
          Button("Take off") {
            adding.removeAll { $0.id == file.id }
            thumbnails[file.id] = nil
            model.removeKept([file])
          }
          .buttonStyle(QuietButtonStyle(color: .tangerineInk))
          .accessibilityLabel("Take off \(file.name)")
        }
        .accessibilityElement(children: .contain)
      }
      HStack(spacing: 24) {
        PhotosPicker(selection: $picks, maxSelectionCount: max(1, room), matching: .images, preferredItemEncoding: .compatible) {
          Label("Photos", systemImage: "photo.on.rectangle")
        }
        .accessibilityLabel("Add photos")
        .accessibilityIdentifier("edit.addPhotos")
        Button("Camera", systemImage: "camera") { camera = true }
          .accessibilityLabel("Take a photo")
          .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))
        Button("Record", systemImage: "mic") { recording = true }
          .accessibilityLabel("Record a voice memo")
      }
      .buttonStyle(QuietButtonStyle())
      .disabled(room <= 0)
      // On the one row: a Section's modifiers can go on each of its rows.
      .onChange(of: picks) { _, items in
        guard !items.isEmpty else { return }
        picks = []
        importing += 1
        Task {
          for item in items { await keepPhoto(try? await item.loadTransferable(type: Data.self)) }
          importing -= 1
        }
      }
      .fullScreenCover(isPresented: $camera) {
        CameraView { data in
          camera = false
          guard let data else { return }
          importing += 1
          Task {
            await keepPhoto(data)
            importing -= 1
          }
        }
        .ignoresSafeArea()
      }
      .sheet(isPresented: $recording) {
        RecorderView { data in
          importing += 1
          Task {
            await keepRecording(data)
            importing -= 1
          }
        }
          .presentationDetents([.medium]).presentationBackground(Color.paper)
      }
    } header: {
      SectionHead("Files")
    } footer: {
      if importing > 0 {
        SectionNote("Getting the new files ready…")
      } else if let line = problem ?? refusal {
        SectionNote(line)
      } else if !removing.isEmpty {
        SectionNote("A file taken off goes when you save, with its transcript or description.")
      }
    }
  }

  private func keepPhoto(_ data: Data?) async {
    guard room > 0 else {
      problem = AppModel.tooManyFiles
      return
    }
    let n = files.filter { $0.kind == "image" }.count + adding.filter(\.isPhoto).count + 1
    switch await model.keepPhoto(data, number: n) {
    case .success(let kept):
      adding.append(kept.file)
      thumbnails[kept.file.id] = kept.thumbnail
      problem = nil
    case .failure(let refused): problem = refused.message
    }
  }

  private func keepRecording(_ data: Data) async {
    guard room > 0 else {
      problem = AppModel.tooManyFiles
      return
    }
    let n = files.filter { $0.kind == "audio" }.count + adding.filter(\.isRecording).count + 1
    switch await model.keepRecording(data, number: n) {
    case .success(let file):
      adding.append(file)
      problem = nil
    case .failure(let refused): problem = refused.message
    }
  }

  /// What a file is called here: its own name, or what it is.
  static func name(_ file: NoteFileEntry) -> String {
    if let name = file.name, !name.isEmpty { return name }
    return switch file.kind {
    case "image": "Photo \(file.n)"
    case "audio": "Voice memo \(file.n)"
    default: "File \(file.n)"
    }
  }

  private static func icon(_ symbol: String) -> some View {
    Image(systemName: symbol)
      .foregroundStyle(Color.ink3)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Color.ink3.opacity(0.12), in: .rect(cornerRadius: 6))
  }
}

/// A note Release Notes refused, fixed and sent again under a new key: its
/// words changed, or the files it refused (a token that can't add files)
/// left off, down to the words alone.
struct FixWaitingView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  let item: OutboxItem
  @State private var text = ""
  /// The files the note still goes with.
  @State private var keeping: Set<UUID> = []

  var body: some View {
    NavigationStack {
      Form {
        Group {
          if let refusal = item.refusal { Section { Text(refusal).foregroundStyle(Color.tangerineInk) } }
          TextField("Note", text: $text, axis: .vertical).lineLimit(3...20)
          if !item.files.isEmpty {
            Section {
              ForEach(item.files) { file in
                Toggle(isOn: Binding(get: { keeping.contains(file.id) },
                                     set: { if $0 { keeping.insert(file.id) } else { keeping.remove(file.id) } })) {
                  Label(file.name, systemImage: file.isPhoto ? "photo" : file.isRecording ? "waveform" : "doc")
                }
              }
            } header: {
              SectionHead("Files")
            } footer: {
              SectionNote("A file turned off is left off the note and taken off this phone. With every file off, the words go alone.")
            }
          }
          Section { CopyWordsButton(text: text) }
        }
        .paperRows()
      }
      .paperForm()
      .navigationTitle("Fix and send")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          Button("Send") {
            Task {
              if await model.retry(item, text: text, keeping: item.files.isEmpty ? nil : keeping) { dismiss() }
            }
          }
          // Nothing left to send.
          .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && keeping.isEmpty)
        }
      }
      .onAppear {
        text = item.text ?? ""
        keeping = Set(item.files.map(\.id))
      }
    }
  }
}

/// Puts a refused note's words on the clipboard, so they outlive a Discard.
struct CopyWordsButton: View {
  let text: String

  var body: some View {
    Button("Copy the words", systemImage: "doc.on.doc") { UIPasteboard.general.string = text }
      .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
  }
}

extension OutboxItem {
  /// New words for a note this token wrote, which a refusal lets the owner
  /// open again.
  var isEdit: Bool {
    if case .edit = operation { true } else { false }
  }
}
