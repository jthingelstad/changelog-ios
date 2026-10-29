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
          TagRowView()
          HStack {
            if let sticky = model.sticky {
              Label("#\(sticky) on every note", systemImage: "pin.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
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
                  if item.refusal != nil { Button("Fix") { fixing = item } }
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

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(item.text).lineLimit(2)
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
              await model.retry(item, text: text)
              dismiss()
            }
          }
        }
      }
      .onAppear { text = item.text }
    }
  }
}
