import ChangelogKit
import SwiftUI

/// Pinned tags, then the ones used most lately, then Keep a Changelog's
/// words. A tap adds or removes the tag in the draft; a long press makes it
/// sticky, on every note until turned off.
struct TagRowView: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 8) {
        ForEach(model.tagRow, id: \.self) { tag in
          let on = Hashtags.contains(tag, in: model.draft)
          let sticky = model.sticky == tag
          Button {
            model.toggle(tag)
          } label: {
            HStack(spacing: 4) {
              if sticky { Image(systemName: "pin.fill").imageScale(.small) }
              Text("#\(tag)")
            }
            .font(.callout)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(on || sticky ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.12), in: .capsule)
          }
          .buttonStyle(.plain)
          .accessibilityLabel("#\(tag)")
          .accessibilityValue(sticky ? "on every note" : on ? "in this note" : "")
          .accessibilityHint("Double tap to add or remove. Touch and hold to keep it on every note.")
          .contextMenu {
            Button(sticky ? "Stop adding to every note" : "Add to every note", systemImage: "pin") {
              model.toggleSticky(tag)
            }
          }
        }
      }
      .padding(.vertical, 2)
    }
  }
}
