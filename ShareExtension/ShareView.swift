import ChangelogKit
import SwiftUI

struct ShareView: View {
  @Bindable var model: ShareModel

  var body: some View {
    NavigationStack {
      Form {
        Section {
          TextField("What changed?", text: $model.text, axis: .vertical)
            .lineLimit(3...8)
            .accessibilityLabel("Note")
          if !model.files.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
              HStack(spacing: 8) {
                ForEach(model.files) { file in
                  Group {
                    if let thumbnail = model.thumbnails[file.id] {
                      Image(decorative: thumbnail, scale: 1).resizable().scaledToFill()
                    } else {
                      Image(systemName: file.isRecording ? "waveform" : "doc.richtext")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.quaternary)
                    }
                  }
                  .frame(width: 64, height: 64)
                  .clipShape(.rect(cornerRadius: 8))
                  .accessibilityLabel(file.name)
                }
              }
            }
          }
        } footer: {
          if model.skipped > 0 {
            Text(model.skipped == 1
              ? "Release Notes keeps photos, voice memos and PDFs, so one item isn't on this note."
              : "Release Notes keeps photos, voice memos and PDFs, so \(model.skipped) items aren't on this note.")
          }
        }

        if let problem = model.problem {
          Section { Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
        }

        switch model.phase {
        case .loading:
          Section { ProgressView() }
        case .sending:
          Section { Label("Sending…", systemImage: "arrow.up.circle") }
        case .done(let said):
          Section { Text(said) }
        case .ready:
          EmptyView()
        }
      }
      // Swiped away mid-send, the share would still go (the app sends it
      // later), but the owner wouldn't hear how it went.
      .interactiveDismissDisabled(model.phase == .sending)
      .navigationTitle("Changelog")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { model.cancel() }.disabled(model.phase == .sending)
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Commit") { Task { await model.commit() } }
            .buttonStyle(.borderedProminent)
            .disabled(!model.canCommit)
        }
      }
    }
  }
}
