import SwiftUI

/// The optional lock on reading, in Settings: off until turned on, and it
/// never stands in the way of adding a note.
struct ReadingLockSection: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    Section {
      if ReadingLock.available {
        Toggle("Lock reading", isOn: Binding(
          get: { model.lockOn },
          set: { on in Task { await model.setLock(on) } }))
      } else {
        Text("To lock reading, set a passcode on this iPhone.").foregroundStyle(Color.ink2)
      }
    } header: {
      SectionHead("Reading")
    } footer: {
      SectionNote("Notes, and what you wrote elsewhere on Log's Today, ask for \(ReadingLock.name) each time you come back to Changelog. Adding a note never asks: Log, Share and Siri stay as they are.")
    }
  }
}
