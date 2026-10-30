import AuthenticationServices
import ChangelogKit
import SwiftUI

/// Sign-in with Release Notes: its own page, in a sheet, asks the owner to
/// name the token Changelog keeps and choose what it may do. A token made in
/// Release Notes' Settings and pasted here works as well.
struct SignInView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.openURL) private var openURL
  @Environment(\.webAuthenticationSession) private var webAuthenticationSession
  @State private var pasted = ""
  @State private var problem: String?
  @State private var pasteProblem: String?
  @State private var checking = false

  var body: some View {
    @Bindable var model = model
    NavigationStack {
      Form {
        Section {
          Text("Changelog sends notes, photos, voice memos and where you are into your Release Notes, and keeps your Upcoming dates. It can read back only the notes it sent, never the rest.")
        } footer: {
          // Why the app signed out (a token revoked or expired, or one it
          // couldn't end), until a sign-in here has its own answer.
          if problem == nil, pasteProblem == nil, let reason = model.problem {
            Text(reason).foregroundStyle(.orange).accessibilityIdentifier("signed-out-reason")
          }
        }
        Section {
          Button("Sign in with Release Notes") { signInWithReleaseNotes() }
            .bold()
            .disabled(checking)
        } footer: {
          VStack(alignment: .leading, spacing: 6) {
            Text("Release Notes asks you to name the token Changelog keeps, what it may do and when it ends. You can end it there any time, under Settings, API tokens.")
            if let problem { Text(problem).foregroundStyle(.orange) }
          }
        }
        Section {
          Text("Make a token in Release Notes under Settings, API tokens, with all four ticked: “Add notes”, “Add files”, “Read and change your Upcoming dates” and “Read the activity log”. Then paste it here.")
            .foregroundStyle(.secondary)
          SecureField("rn_…", text: $pasted)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .textContentType(.password)
            .onSubmit { check(pasted) }
          Button("Paste token") {
            if let text = UIPasteboard.general.string { check(text) }
          }
          Button("Sign in with this token") { check(pasted) }
            .disabled(checking || pasted.isEmpty)
          Button("Open Release Notes Settings") { openURL(Links.settings) }
        } header: {
          Text("Or use a token")
        } footer: {
          if let pasteProblem { Text(pasteProblem).foregroundStyle(.orange) }
        }
        Section {
          Button("Privacy") { openURL(Links.privacy) }
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

  private func signInWithReleaseNotes() {
    checking = true
    problem = nil
    pasteProblem = nil
    Task {
      problem = await model.signInWithReleaseNotes { url in
        do {
          // The shared browser session, so someone already signed in to
          // Release Notes in Safari goes straight to what Changelog asks.
          return try await webAuthenticationSession.authenticate(
            using: url, callback: .customScheme(SignIn.callbackScheme),
            preferredBrowserSession: .shared, additionalHeaderFields: [:])
        } catch ASWebAuthenticationSessionError.canceledLogin {
          return nil
        }
      }
      checking = false
    }
  }

  private func check(_ raw: String) {
    checking = true
    problem = nil
    pasteProblem = nil
    Task {
      pasteProblem = await model.signIn(with: raw)
      checking = false
      if pasteProblem != nil { pasted = "" }
    }
  }
}
