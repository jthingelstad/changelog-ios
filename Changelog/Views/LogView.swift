import ChangelogKit
import SwiftUI

/// The home screen: today's version, the box, the tag row, Commit, and what
/// happened today from every channel.
struct LogView: View {
  @Environment(AppModel.self) private var model
  @FocusState private var typing: Bool
  @State private var editing: ActivityItem?
  @State private var fixing: OutboxItem?

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
          HStack {
            ComposerTools()
            Spacer()
            Button("Commit") {
              Task { await model.commit() }
            }
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
                  if item.refusal != nil && item.isNote { Button("Fix") { fixing = item } }
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
            ActivityRow(item: item)
              .swipeActions {
                if model.isMine(item) {
                  Button("Delete", role: .destructive) { Task { await model.delete(item) } }
                  Button("Edit") { editing = item }
                }
              }
          }
        }
      }
      .navigationTitle("Changelog")
      .toolbarTitleDisplayMode(.inline)
      .refreshable { await model.refresh() }
      .onAppear { typing = true }
      .onChange(of: model.draft) { before, now in
        if before.isEmpty, !now.isEmpty { Task { await model.draftStarted() } }
      }
      .overlay(alignment: .bottom) { Toast() }
      .sheet(item: $editing) { item in EditNoteView(item: item) }
      .sheet(item: $fixing) { item in FixWaitingView(item: item) }
    }
  }
}

struct VersionHeader: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    HStack(alignment: .firstTextBaseline) {
      Text(model.version ?? "…")
        .font(.version)
        .accessibilityLabel(model.version.map { "Version \($0)" } ?? "Version loading")
      Spacer()
      if let me = model.me {
        if me.status == "stopped" {
          Text("Email stopped").font(.caption).foregroundStyle(.secondary)
        } else if me.streak > 1 {
          Text("\(me.streak)-day streak").font(.caption).foregroundStyle(.secondary)
        }
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
        Text(item.attempts == 0 ? "Sending…" : "Waiting for a connection")
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
    }
  }
}

/// Edits a note this token wrote, from the revision it read.
struct EditNoteView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  let item: ActivityItem
  @State private var note: NoteDetail?
  @State private var text = ""
  @State private var saving = false

  var body: some View {
    NavigationStack {
      Form {
        if note == nil {
          ProgressView()
        } else {
          TextField("Note", text: $text, axis: .vertical).lineLimit(3...20)
        }
      }
      .navigationTitle(item.version.map { "Edit in \($0)" } ?? "Edit")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save") {
            guard let note else { return }
            saving = true
            Task {
              if await model.save(note, text: text) { dismiss() }
              saving = false
            }
          }
          .disabled(note == nil || saving || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
      }
      .task {
        note = await model.load(item)
        text = note?.text ?? ""
      }
    }
  }
}

/// A note Release Notes refused, edited and sent again under a new key.
struct FixWaitingView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  let item: OutboxItem
  @State private var text = ""

  var body: some View {
    NavigationStack {
      Form {
        if let refusal = item.refusal { Section { Text(refusal).foregroundStyle(.orange) } }
        TextField("Note", text: $text, axis: .vertical).lineLimit(3...20)
      }
      .navigationTitle("Fix and send")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          Button("Send") {
            Task {
              if await model.retry(item, text: text) { dismiss() }
            }
          }
        }
      }
      .onAppear { text = item.text ?? "" }
    }
  }
}
