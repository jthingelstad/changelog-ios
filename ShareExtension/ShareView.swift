import ChangelogKit
import SwiftUI

struct ShareView: View {
  @Bindable var model: ShareModel

  var body: some View {
    NavigationStack {
      Form {
        Group {
          Section {
            TextField("Note", text: $model.text, prompt: Text("What changed?").foregroundStyle(Color.ink3), axis: .vertical)
              .face(.writing)
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
              SectionNote(model.skipped == 1
                ? "Release Notes keeps photos, voice memos and PDFs, so one item isn't on this note."
                : "Release Notes keeps photos, voice memos and PDFs, so \(model.skipped) items aren't on this note.")
            }
          }

          if let problem = model.problem {
            Section { Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(Color.tangerineInk) }
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
        .paperRows()
      }
      .paperForm()
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
          // The web's tangerine, with navy words, as Commit is in the app.
          Button { Task { await model.commit() } } label: {
            Text("Commit").face(.commit).foregroundStyle(Color.onTangerine)
          }
          .buttonStyle(.borderedProminent)
          .tint(Color.tangerine)
          .disabled(!model.canCommit)
        }
      }
    }
  }
}
