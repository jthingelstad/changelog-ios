import ChangelogKit
import SwiftUI

struct SettingsView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.openURL) private var openURL
  @State private var confirmSignOut = false

  var body: some View {
    @Bindable var model = model
    NavigationStack {
      Form {
        Group {
          Section {
            VStack(alignment: .leading, spacing: 0) {
              BrandBar()
              PageTitle(title: "Settings", lede: "This phone's connection, notifications and place. The rest is on the web.")
                .padding(.top, 22)
            }
            .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 8, trailing: 20))
            .listRowSeparator(.hidden)
          }

          Section {
            if let me = model.me {
              LabeledContent("Token", value: me.token.name)
              LabeledContent("Can", value: me.token.scopes.map(Self.scopeName).joined(separator: ", "))
              if let expires = me.token.expiresAt.flatMap({ try? Date($0, strategy: .iso8601) }) {
                LabeledContent("Expires", value: expires.formatted(date: .abbreviated, time: .omitted))
              }
            }
            // There before /v1/me answers too, so a phone that can't reach
            // Release Notes can still sign out.
            Button("Sign out", role: .destructive) { confirmSignOut = true }
          } header: {
            SectionHead("This connection")
          }

          Section {
            if model.canRemind {
              Toggle("Remind me on this phone", isOn: Binding(
                get: { model.remindersOn },
                set: { on in Task { await model.setReminders(on) } }))
            } else {
              Text("To get them here, make a token with “Read and change your Upcoming dates and their reminders” ticked.")
                .foregroundStyle(Color.ink2)
            }
          } header: {
            SectionHead("Upcoming reminders")
          } footer: {
            SectionNote(model.remindersProblem ?? "The reminders each morning's email carries, as notifications here when that email is due, in its words. They still come while your email is paused or stopped. Dates with email reminders off don't come.",
                        problem: model.remindersProblem != nil)
          }

          if model.readsNotes { ReadingLockSection() }

          NotificationSettings()

          Section {
            Toggle("Add where I am", isOn: $model.hereByDefault)
          } header: {
            SectionHead("Place")
          } footer: {
            SectionNote("Each note from this phone takes the neighbourhood or city it was written in, and you can pick a business nearby. Off, tap the location button for a note that should have one.")
          }

          CheckInSection()

          Section {
            NavigationLink("Pinned tags") { PinnedTagsView() }
            if let sticky = model.stickyTag {
              Button("Stop adding \(sticky.name) to every note") { model.sticky = nil }
            }
          } header: {
            SectionHead("Tags")
          } footer: {
            SectionNote("Pinned tags are the same here, on the web and on every phone. Touch and hold a tag on Log to add it to every note from this phone.")
          }

          AppIconSection(member: model.me?.supportingMember == true)

          Section {
            Button("Open Release Notes") { openURL(Links.site) }
            Button("Settings on the web") { openURL(Links.settings) }
            Button("The guide") { openURL(Links.guide) }
            Button("Privacy") { openURL(Links.privacy) }
            Button("Delete your account") { openURL(Links.delete) }
          } header: {
            SectionHead("Release Notes")
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
            SectionNote("The dev server is tools/dev-server.ts in the Release Notes repo, with its fictional account. Sign out and in again after switching.")
          }
          #endif

          Section {
          } footer: {
            Text(Build.line).face(.time).foregroundStyle(Color.ink3).accessibilityIdentifier("build")
          }
        }
        .paperRows()
      }
      .paperForm()
      .navigationTitle("Settings")
      .toolbar(.hidden, for: .navigationBar)
      .confirmationDialog("Sign out of Changelog?", isPresented: $confirmSignOut, titleVisibility: .visible) {
        Button("Sign out and revoke this token", role: .destructive) { Task { await model.signOut() } }
      } message: {
        Text("The token stops working everywhere. Notes still waiting stay on this phone.")
      }
    }
  }

  static func scopeName(_ scope: String) -> String {
    switch scope {
    case "notes:write": "add notes"
    case "media:write": "add files"
    case "upcoming": "Upcoming"
    case "activity": "read activity"
    case "notes:all": "read and change all notes"
    case "notes:read": "read all notes"
    default: scope
    }
  }
}

/// The pins, by name, the same on every device (API 1.21.0): at most 12,
/// first in the tag row. Each goes in as a tags field takes a tag.
struct PinnedTagsView: View {
  @Environment(AppModel.self) private var model
  @State private var pinned: [Tag] = []
  @State private var adding = ""
  @State private var problem: String?

  static let most = 12

  var body: some View {
    Form {
      Section {
        ForEach(pinned) { Text(verbatim: $0.name).foregroundStyle(Color.cobalt) }
          .onDelete { pinned.remove(atOffsets: $0) }
          .onMove { pinned.move(fromOffsets: $0, toOffset: $1) }
        HStack {
          TextField("Add a tag", text: $adding)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .onSubmit(add)
            .onChange(of: adding) { _, _ in problem = nil }
          Button("Add", action: add)
            .disabled(adding.trimmingCharacters(in: .whitespaces).isEmpty || pinned.count >= Self.most)
        }
      } footer: {
        SectionNote(problem ?? "Up to \(Self.most). They come first in the tag row.", problem: problem != nil)
      }
      .paperRows()
    }
    .paperForm()
    .navigationTitle("Pinned tags")
    // Settings hides its bar; this screen needs Back and Edit.
    .toolbar(.visible, for: .navigationBar)
    .toolbar { EditButton() }
    .onAppear { pinned = model.tags?.pinnedTags ?? [] }
    .onDisappear {
      let before = model.tags?.pinnedTags ?? []
      if pinned.map(\.key) != before.map(\.key) || pinned.map(\.name) != before.map(\.name) {
        Task { await model.setPinned(pinned) }
      }
    }
  }

  private func add() {
    guard pinned.count < Self.most else { return }
    switch Hashtags.adding(adding, to: pinned) {
    case .failure(let why):
      problem = why.said
    case .success(let done):
      pinned = done.tags
      adding = ""
    }
  }
}
