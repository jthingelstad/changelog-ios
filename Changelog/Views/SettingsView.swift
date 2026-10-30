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

          NotificationSettings()

          Section {
            Toggle("Add where I am", isOn: $model.hereByDefault)
          } header: {
            SectionHead("Place")
          } footer: {
            SectionNote("Each note from this phone takes the neighbourhood or city it was written in, and you can pick a business nearby. Off, tap the location button for a note that should have one.")
          }

          Section {
            NavigationLink("Pinned tags") { PinnedTagsView() }
            if let sticky = model.sticky {
              Button("Stop adding #\(sticky) to every note") { model.sticky = nil }
            }
          } header: {
            SectionHead("Tags")
          } footer: {
            SectionNote("Pinned tags are the same here, on the web and on every phone. Touch and hold a tag on Log to add it to every note from this phone.")
          }

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
    default: scope
    }
  }
}

struct PinnedTagsView: View {
  @Environment(AppModel.self) private var model
  @State private var pinned: [String] = []
  @State private var adding = ""

  var body: some View {
    Form {
      Section {
        ForEach(pinned, id: \.self) { Text("#\($0)").foregroundStyle(Color.cobalt) }
          .onDelete { pinned.remove(atOffsets: $0) }
          .onMove { pinned.move(fromOffsets: $0, toOffset: $1) }
        HStack {
          TextField("Add a tag", text: $adding)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .onSubmit(add)
          Button("Add", action: add).disabled(Hashtags.normalize(adding) == nil || pinned.count >= 12)
        }
      } footer: {
        SectionNote("Up to 12. They come first in the tag row.")
      }
      .paperRows()
    }
    .paperForm()
    .navigationTitle("Pinned tags")
    .toolbar { EditButton() }
    .onAppear { pinned = model.tags?.pinned ?? [] }
    .onDisappear {
      if pinned != (model.tags?.pinned ?? []) { Task { await model.setPinned(pinned) } }
    }
  }

  private func add() {
    guard let tag = Hashtags.normalize(adding), !pinned.contains(tag), pinned.count < 12 else { return }
    pinned.append(tag)
    adding = ""
  }
}
