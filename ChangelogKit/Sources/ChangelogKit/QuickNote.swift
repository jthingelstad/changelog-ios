import Foundation

/// A note sent from outside the app's screens: the share sheet, or a
/// shortcut and Siri. It goes in a queue of its own in the App Group's
/// `shares/` folder (`ShareInbox`), is sent from there if it can be within
/// a deadline, and is otherwise left for the app, which adopts it under the
/// same key: sent by both, it is still one note.
public enum QuickNote {
  public enum Outcome: Sendable, Equatable {
    case filed(NoteReceipt)
    /// Filed, in an answer this build couldn't read.
    case sent
    /// The server's reason. The note waits in the app to fix.
    case refused(String)
    case signedOut
    /// Offline, rate limited or out of time: the app sends it.
    case waiting
    /// No token here: the app sends it once someone signs in.
    case noToken
  }

  /// Sends `share`'s queue, giving up after `deadline`, and hands what is
  /// left to the app.
  public static func send(_ share: (outbox: Outbox, file: URL), from inbox: ShareInbox, with client: APIClient?,
                          within deadline: Duration) async -> Outcome {
    guard let client else {
      inbox.close(share.file, sent: false)
      return .noToken
    }
    let outbox = share.outbox
    let sending = Task {
      await outbox.flush(prepare: { item, folder throws(APIError) in try await client.prepare(item, files: folder) }) {
        item throws(APIError) in try await client.perform(item)
      }
    }
    let timer = Task {
      try? await Task.sleep(for: deadline)
      sending.cancel()
    }
    let report = await sending.value
    timer.cancel()
    inbox.close(share.file, sent: await outbox.waiting.isEmpty)
    if let receipt = report.filed.first { return .filed(receipt) }
    if report.sent.contains(where: { $0.result == .done }) { return .sent }
    if let refused = report.refused.first?.refusal { return .refused(refused) }
    if report.stopped?.signedOut == true { return .signedOut }
    return .waiting
  }

  /// What the share sheet, Siri or a shortcut says after. Never the note's
  /// words: Siri may say it aloud.
  public static func said(_ outcome: Outcome) -> String {
    switch outcome {
    case .filed(let receipt):
      let badges = receipt.unlocked ?? []
      return badges.isEmpty ? "Filed in \(receipt.note.version)." : "Unlocked: \(badges.map(\.name).joined(separator: ", "))"
    case .sent: return "Filed."
    case .refused(let why): return why + " It waits in Changelog to fix."
    case .signedOut: return "Saved. Sign in to Changelog again and it goes from there."
    case .waiting: return "Saved. Changelog sends it when it can."
    case .noToken: return "Saved. Open Changelog to send it."
    }
  }

  /// The words as the app would send them: trimmed, with the sticky tag the
  /// app mirrors into the App Group.
  public static func words(_ text: String, sticky: String? = AppGroup.defaults?.string(forKey: "sticky")) -> String {
    let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let sticky else { return words }
    return Hashtags.adding(sticky, to: words)
  }

  /// A client with the token and server the app left in the App Group, or
  /// nil when no one is signed in.
  public static func client(userAgent: String) -> APIClient? {
    guard let token = KeychainTokenStore(accessGroup: AppGroup.id).read() else { return nil }
    #if DEBUG
    let server = AppGroup.defaults?.string(forKey: "server").flatMap(URL.init(string:)) ?? APIClient.production
    #else
    // A release build sends to Release Notes alone, as the app does.
    let server = APIClient.production
    #endif
    return APIClient(baseURL: server, token: token, userAgent: userAgent)
  }
}
