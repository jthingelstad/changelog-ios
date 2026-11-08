import ChangelogKit
import SwiftUI

/// Pinned tags, then the ones used most lately, then Keep a Changelog's
/// words, each by its name. A tap puts the tag on the draft or takes it off
/// (its #words too, call 1); a long press makes it sticky, on every note
/// until turned off.
struct TagRowView: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    // Tags as words, as the web's tag row has them: cobalt and underlined
    // to add, ink and bold once on the note (or on every note).
    let chips = Set(model.draftChips.map(\.key))
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 18) {
        ForEach(model.tagRow) { tag in
          let on = chips.contains(tag.key)
          let sticky = model.stickyTag?.key == tag.key
          Button {
            model.toggle(tag)
          } label: {
            HStack(spacing: 4) {
              if sticky { Image(systemName: "pin.fill").imageScale(.small) }
              Text(verbatim: tag.name).underline(!(on || sticky), color: .cobalt)
            }
            .face(on || sticky ? .tagOn : .tag)
            .foregroundStyle(on || sticky ? Color.ink : Color.cobalt)
            .frame(minHeight: 40)
            .contentShape(.rect)
          }
          .buttonStyle(.plain)
          .accessibilityLabel(tag.name)
          .accessibilityValue(sticky ? "on every note" : on ? "on this note" : "")
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
