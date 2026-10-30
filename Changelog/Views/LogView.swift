import ChangelogKit
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
              if model.isMine(item) {
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
      // Jamie, 2026-10-30: a swipe asks before a note goes for good.
      .confirmationDialog("Delete this note?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                          titleVisibility: .visible, presenting: deleting) { item in
        Button("Delete", role: .destructive) { Task { await model.delete(item) } }
      } message: { _ in
        Text("It goes from Release Notes, with its photos and files. This can't be undone.")
      }
      // A held note's Delete asks first too.
      .confirmationDialog(discarding?.isNote == false ? "Delete this change?" : "Delete this note?",
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
/// capitals, the version large, and the version that ships next.
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
  let item: OutboxItem
  /// Why it is held, in place of its status: written under another account.
  var held: String? = nil

  private var summary: String {
    switch item.operation {
    case .note(let text, _, _): text
    case .edit(_, _, let text, _): "Edit: \(text)"
    case .delete(let date, _): "Delete a note from \(date)"
    case .pins(let pinned): pinned.isEmpty ? "Unpin every tag" : "Pin " + pinned.map { "#\($0)" }.joined(separator: " ")
    case .post(let post):
      post.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Self.count(post.files) : post.text
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
          try? await Task.sleep(for: .seconds(2.5))
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
              SectionNote("Your words are below. Saving puts them in place of what the note says now.")
            }
          }
          if let failure {
            Section {
              Label(Self.sentence(failure), systemImage: "exclamationmark.triangle").foregroundStyle(Color.tangerineInk)
              if failure.retryable { Button("Try again") { Task { await read() } } }
            }
          }
          if note != nil || refused != nil {
            TextField("Note", text: $text, axis: .vertical).lineLimit(3...20)
          } else if failure == nil {
            ProgressView()
          }
          if refused != nil {
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
      .navigationTitle(title)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save") {
            guard let note else { return }
            saving = true
            Task {
              var kept = false
              if let refused {
                kept = await model.retry(refused, text: text, revision: note.revision)
              } else {
                kept = await model.save(note, text: text)
              }
              if kept { dismiss() }
              saving = false
            }
          }
          .disabled(note == nil || saving || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
      }
      .task { await read() }
    }
  }

  private func read() async {
    failure = nil
    do {
      let read = try await model.load(date: date, id: id)
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
