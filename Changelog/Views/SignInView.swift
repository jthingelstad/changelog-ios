import ChangelogKit
import SwiftUI

/// Sign-in by token, until OAuth comes (Changelog 1.0). The owner makes a
/// token in Release Notes' Settings and pastes it here.
struct SignInView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.openURL) private var openURL
  @State private var pasted = ""
  @State private var problem: String?
  @State private var checking = false

  var body: some View {
    @Bindable var model = model
    NavigationStack {
      Form {
        Section {
          Text("Changelog sends notes, photos and voice memos, and soon dates, into your Release Notes. It can read back only the notes it sent, never the rest.")
          Text("Make a token in Release Notes under Settings, API tokens, with “Add notes” and “Read the activity log” ticked. Then paste it here.")
            .foregroundStyle(.secondary)
        }
        Section {
          SecureField("rn_…", text: $pasted)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .textContentType(.password)
            .onSubmit { check(pasted) }
          Button("Paste token") {
            if let text = UIPasteboard.general.string { check(text) }
          }
        } footer: {
          if let problem { Text(problem).foregroundStyle(.orange) }
        }
        Section {
          Button("Sign in") { check(pasted) }
            .disabled(checking || pasted.isEmpty)
          Button("Open Release Notes Settings") { openURL(Links.settings) }
        }
        #if DEBUG
        Section {
          Picker("Server", selection: $model.server) {
            Text("Release Notes").tag(APIClient.production)
            Text("Dev server").tag(APIClient.devServer)
          }
        } header: {
          Text("Development")
        } footer: {
          Text("The dev server prints a token for its fictional account when it starts.")
        }
        #endif
      }
      .navigationTitle("Changelog")
      .overlay { if checking { ProgressView() } }
    }
  }

  private func check(_ raw: String) {
    checking = true
    Task {
      problem = await model.signIn(with: raw)
      checking = false
      if problem != nil { pasted = "" }
    }
  }
}
