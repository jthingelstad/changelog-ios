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
        Group {
          Section {
            // The mark and the name, large, over what Changelog does.
            VStack(alignment: .leading, spacing: 14) {
              BrandMark(size: 56)
              Text("Changelog").face(.title).foregroundStyle(Color.ink).accessibilityAddTraits(.isHeader)
              Text("Changelog sends notes, photos, voice memos and where you are into your Release Notes, keeps your Upcoming dates, and reads your notes here if you let it.")
                .face(.lede)
                .foregroundStyle(Color.ink2)
            }
            .padding(.top, 40)
            .listRowSeparator(.hidden)
          } footer: {
            // Why the app signed out (a token revoked or expired, or one it
            // couldn't end), until a sign-in here has its own answer.
            if problem == nil, pasteProblem == nil, let reason = model.problem {
              SectionNote(reason, problem: true).accessibilityIdentifier("signed-out-reason")
            }
          }
          Section {
            Button { signInWithReleaseNotes() } label: {
              Text("Sign in with Release Notes").frame(maxWidth: .infinity)
            }
            .buttonStyle(CommitButtonStyle())
            .disabled(checking)
            .listRowSeparator(.hidden)
          } footer: {
            VStack(alignment: .leading, spacing: 6) {
              SectionNote("Release Notes asks you to name the token Changelog keeps, what it may do and when it ends. You can end it there any time, under Settings, API tokens.")
              if let problem { SectionNote(problem, problem: true) }
            }
          }
          Section {
            Text("Make a token in Release Notes under Settings, API tokens, with all five ticked: “Add notes”, “Add files”, “Read all your notes”, “Read and change your Upcoming dates” and “Read the activity log”. Then paste it here.")
              .face(.hint)
              .foregroundStyle(Color.ink2)
            SecureField("rn_…", text: $pasted)
              .textInputAutocapitalization(.never)
              .autocorrectionDisabled()
              .textContentType(.password)
              .onSubmit { check(pasted) }
            Button("Paste token") {
              // Counted before it is read, so a copy made meanwhile never
              // matches and is never cleared.
              let copied = UIPasteboard.general.changeCount
              if let text = UIPasteboard.general.string { check(text, copied: copied) }
            }
            Button("Sign in with this token") { check(pasted) }
              .disabled(checking || pasted.isEmpty)
            Button("Open Release Notes Settings") { openURL(Links.settings) }
          } header: {
            SectionHead("Or use a token")
          } footer: {
            if let pasteProblem { SectionNote(pasteProblem, problem: true) }
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
            SectionHead("Development")
          } footer: {
            SectionNote("The dev server prints a token for its fictional account when it starts.")
          }
          #endif
        }
        .paperRows()
      }
      .paperForm()
      .navigationTitle("Changelog")
      .toolbar(.hidden, for: .navigationBar)
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

  /// `copied` is the clipboard's change count when the token was taken from
  /// it. Signed in, the token leaves the clipboard if the clipboard still
  /// holds it: unchanged since, by its count, which reads without iOS asking
  /// to paste again.
  private func check(_ raw: String, copied: Int? = nil) {
    checking = true
    problem = nil
    pasteProblem = nil
    Task {
      pasteProblem = await model.signIn(with: raw)
      checking = false
      if pasteProblem != nil {
        pasted = ""
      } else if let copied, UIPasteboard.general.changeCount == copied {
        UIPasteboard.general.items = []
      }
    }
  }
}
