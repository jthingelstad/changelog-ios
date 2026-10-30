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

  var body: some View {
    @Bindable var model = model
    NavigationStack {
      List {
        Section {
          VersionHeader()
          TextField("What changed?", text: $model.draft, axis: .vertical)
            .lineLimit(3...10)
            .focused($typing)
            .submitLabel(.return)
            .accessibilityLabel("Note")
          if !model.draftFiles.isEmpty { AttachmentStrip() }
          TagRowView()
          if model.placeLabel != nil || model.sticky != nil {
            HStack {
              PlaceMenu()
              Spacer()
              if let sticky = model.sticky {
                Label("#\(sticky) on every note", systemImage: "pin.fill")
                  .font(.caption)
                  .foregroundStyle(.secondary)
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
              Task { await model.commit() }
            }
            .lineLimit(1)
            .buttonStyle(.borderedProminent)
            .disabled(!model.canCommit)
            .keyboardShortcut(.return, modifiers: .command)
          }
        }

        if let problem = model.problem {
          Section { Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
        }

        if !model.waiting.isEmpty {
          Section("Waiting to send") {
            ForEach(model.waiting) { item in
              WaitingRow(item: item)
                .swipeActions {
                  Button("Discard", role: .destructive) { Task { await model.discard(item) } }
                  if item.refusal != nil && (item.isNote || item.isEdit) { Button("Fix") { fixing = item } }
                }
            }
          }
        }

        Section("Today") {
          if model.today.isEmpty {
            Text(model.version.map { "No changes yet in \($0)." } ?? "Nothing yet today.")
              .foregroundStyle(.secondary)
          }
          ForEach(model.today) { item in
            ActivityRow(item: item, words: model.words(of: item))
              .swipeActions {
                if model.isMine(item) {
                  Button("Delete", role: .destructive) { deleting = item }
                  Button("Edit") { editing = item }
                }
              }
          }
        }
      }
      .navigationTitle("Changelog")
      .toolbarTitleDisplayMode(.inline)
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
}

struct VersionHeader: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    // The streak beside the version while both fit on one line, else
    // under it (at the larger text sizes).
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .firstTextBaseline) {
        version
        Spacer()
        streak
      }
      VStack(alignment: .leading, spacing: 2) {
        version
        streak
      }
    }
  }

  /// A version is never broken or cut off: on one line, and smaller
  /// before it would be too wide for the row.
  private var version: some View {
    Text(model.version ?? "…")
      .font(.version)
      .lineLimit(1)
      .minimumScaleFactor(0.5)
      .accessibilityLabel(model.version.map { "Version \($0)" } ?? "Version loading")
  }

  @ViewBuilder private var streak: some View {
    if let me = model.me {
      if me.status == "stopped" {
        Text("Email stopped").font(.caption).foregroundStyle(.secondary)
      } else if me.streak > 1 {
        Text("\(me.streak)-day streak").font(.caption).foregroundStyle(.secondary)
      }
    }
  }
}

struct WaitingRow: View {
  let item: OutboxItem

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
      Text(summary).lineLimit(2)
      if let extras {
        Label(extras, systemImage: "paperclip").font(.caption).foregroundStyle(.secondary)
      }
      if let refusal = item.refusal {
        Text(refusal).font(.caption).foregroundStyle(.orange)
      } else {
        Text(item.status)
          .font(.caption).foregroundStyle(.secondary)
      }
    }
  }
}

struct Toast: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    if let toast = model.toast {
      Text(toast)
        .font(.callout.monospaced())
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.thinMaterial, in: .capsule)
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
        if let refusal = refused?.refusal {
          Section {
            Text(refusal).foregroundStyle(.orange)
          } footer: {
            Text("Your words are below. Saving puts them in place of what the note says now.")
          }
        }
        if let failure {
          Section {
            Label(Self.sentence(failure), systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
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
            Section("What it says now") { Text(verbatim: note.text).foregroundStyle(.secondary).textSelection(.enabled) }
          }
        }
      }
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
        if let refusal = item.refusal { Section { Text(refusal).foregroundStyle(.orange) } }
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
            Text("Files")
          } footer: {
            Text("A file turned off is left off the note and taken off this phone. With every file off, the words go alone.")
          }
        }
        Section { CopyWordsButton(text: text) }
      }
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
