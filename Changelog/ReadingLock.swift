import Foundation
import LocalAuthentication

/// The optional lock on reading (Jamie, 2026-11-05: on reading, never on
/// capture, off until turned on). Face ID or Touch ID, else the passcode.
enum ReadingLock {
  /// Whether this phone can ask at all: it has a passcode.
  static var available: Bool {
    if standIn != nil { return true }
    return LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
  }

  /// What this phone asks with, for the words beside the switch.
  static var name: String {
    let context = LAContext()
    _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
    return switch context.biometryType {
    case .touchID: "Touch ID"
    case .faceID: "Face ID"
    default: "your passcode"
    }
  }

  static func confirm(_ reason: String) async -> Bool {
    if let standIn { return standIn }
    return (try? await LAContext().evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
  }

  /// A simulator can't look at a face, so the test cycle says how it went
  /// (`CHANGELOG_LOCK_ANSWER`, a debug build only).
  private static var standIn: Bool? {
    #if DEBUG
    ProcessInfo.processInfo.environment["CHANGELOG_LOCK_ANSWER"].map { $0 == "yes" }
    #else
    nil
    #endif
  }
}

/// A note's file on this phone, for as long as it is previewed, in a folder
/// that goes when the preview closes, the lock closes or the app next starts.
enum PreviewFiles {
  private static var folder: URL { FileManager.default.temporaryDirectory.appending(path: "previews") }

  static func keep(_ data: Data, name: String) -> URL? {
    let own = folder.appending(path: UUID().uuidString)
    let file = own.appending(path: name)
    do {
      try FileManager.default.createDirectory(atPath: own.path(percentEncoded: false), withIntermediateDirectories: true)
      try data.write(to: file, options: [.completeFileProtection])
      return file
    } catch {
      return nil
    }
  }

  static func remove(_ file: URL) {
    try? FileManager.default.removeItem(atPath: file.deletingLastPathComponent().path(percentEncoded: false))
  }

  static func sweep() {
    try? FileManager.default.removeItem(atPath: folder.path(percentEncoded: false))
  }
}
