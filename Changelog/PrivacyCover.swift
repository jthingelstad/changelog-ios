import SwiftUI
import UIKit

/// With the lock on, the app switcher's picture shows no note. The cover is a
/// window of its own above the app's, so it is over every sheet, Quick Look
/// and alert the app shows, which an overlay on the tabs would sit under. It
/// shows while `shows`, and goes with the view it is put on.
struct PrivacyCover: UIViewRepresentable {
  let shows: Bool

  func makeUIView(context: Context) -> Anchor { Anchor() }

  func updateUIView(_ anchor: Anchor, context: Context) { anchor.shows = shows }

  static func dismantleUIView(_ anchor: Anchor, coordinator: ()) { anchor.shows = false }

  /// Finds the scene the app is in, and keeps the cover's window there.
  final class Anchor: UIView {
    var shows = false { didSet { update() } }
    private var cover: UIWindow?

    override init(frame: CGRect) {
      super.init(frame: frame)
      isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) { nil }

    override func didMoveToWindow() {
      super.didMoveToWindow()
      update()
    }

    private func update() {
      guard shows, let scene = window?.windowScene else {
        cover?.isHidden = true
        return
      }
      if cover?.windowScene !== scene {
        cover?.isHidden = true
        let window = UIWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        window.rootViewController = UIHostingController(rootView: Cover())
        cover = window
      }
      // Shown, never made key: the app's own window keeps the keyboard and
      // what was being typed.
      cover?.isHidden = false
    }
  }
}

/// The paper and the mark, as the app starts.
private struct Cover: View {
  var body: some View {
    Color.paper.ignoresSafeArea().overlay { BrandMark(size: 56) }
  }
}
