import ChangelogKit
import SwiftUI
import UIKit

/// Settings' App icon section: the icons `AppIcon.offered` gives, each a
/// tap from being the app's.
struct AppIconSection: View {
  let member: Bool
  @State private var current = AppIcon.named(UIApplication.shared.alternateIconName)
  @State private var problem: String?

  var body: some View {
    let offered = AppIcon.offered(member: member, current: current)
    if UIApplication.shared.supportsAlternateIcons, !offered.isEmpty {
      Section {
        ForEach(offered) { icon in
          Button {
            Task { await choose(icon) }
          } label: {
            HStack(spacing: 14) {
              Image(icon.preview)
                .resizable()
                .frame(width: 44, height: 44)
                .clipShape(.rect(cornerRadius: 10, style: .continuous))
                .accessibilityHidden(true)
              Text(icon.title).foregroundStyle(Color.ink)
              Spacer()
              if icon == current {
                Image(systemName: "checkmark").foregroundStyle(Color.cobalt).accessibilityHidden(true)
              }
            }
          }
          .accessibilityAddTraits(icon == current ? .isSelected : [])
          .accessibilityIdentifier("app-icon-\(icon.title)")
        }
      } header: {
        SectionHead("App icon")
      } footer: {
        if let problem {
          SectionNote(problem, problem: true)
        } else if member {
          SectionNote("Four more for Supporting Members of the Weekly Thing, with thanks.")
        }
      }
    }
  }

  private func choose(_ icon: AppIcon) async {
    guard icon != current else { return }
    do {
      try await UIApplication.shared.setAlternateIconName(icon.alternateName)
      current = icon
      problem = nil
    } catch {
      // What iOS has on, whatever it was asked.
      current = AppIcon.named(UIApplication.shared.alternateIconName)
      problem = "iOS didn't change the icon. Try again."
    }
  }
}
