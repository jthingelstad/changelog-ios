import Foundation

/// Trading this phone's token for one that may read, without signing out: the
/// reminder switches, the queue and the account all stay. Nothing is given up
/// until the new token has proved itself and is safely in the Keychain.
public enum TokenSwitch {
  /// What the new token must be, or what to say instead. Nil when it will do.
  /// An owner signed in to another account in the browser gets a token for
  /// that account, which must never take this phone's place.
  public static func refusal(of new: Me, account: String?) -> String? {
    if let account, new.account != account {
      return "That sign-in was a different Release Notes account, so nothing changed. Sign in to the account this phone uses."
    }
    guard new.token.scopes.contains("notes:write") else {
      return "Changelog still needs “Add notes”, so nothing changed. Try again with it ticked."
    }
    guard new.token.readsAll else {
      return "“Read all your notes” wasn't ticked, so nothing changed. Try again with it ticked."
    }
    return nil
  }

  /// Proves `candidate` and keeps it in `store` in place of `current`. Answers
  /// the token's `/v1/me`, or a sentence for the owner, having ended the
  /// candidate and put `current` back. The caller moves to the new token
  /// before it ends the old one, so a send under way never reads as signed out.
  ///
  /// `stillCurrent` says the phone still holds `current`: the owner can sign
  /// out while the token is being proved. This runs on the caller's actor, so
  /// nothing of the caller's can run between that answer, the write and the
  /// caller taking the new token up.
  public static func adopt(
    _ candidate: String,
    replacing current: String,
    account: String?,
    store: any TokenStore,
    stillCurrent: () -> Bool,
    me: @Sendable (String) async throws(APIError) -> Me,
    revoke: @Sendable (String) async -> Void,
    isolation: isolated (any Actor)? = #isolation
  ) async -> Result<Me, Refused> {
    let fresh: Me
    do throws(APIError) {
      fresh = try await me(candidate)
    } catch {
      await revoke(candidate)
      return .failure(Refused(message: error.message))
    }
    if let said = refusal(of: fresh, account: account) {
      await revoke(candidate)
      return .failure(Refused(message: said))
    }
    guard stillCurrent() else {
      await revoke(candidate)
      return .failure(Refused(message: "This phone isn't using that token any more, so nothing changed."))
    }
    do {
      try store.write(candidate)
    } catch {
      // The Keychain clears before it adds, so the old one goes back.
      try? store.write(current)
      await revoke(candidate)
      return .failure(Refused(message: "The new token couldn't be kept on this phone, so nothing changed."))
    }
    return .success(fresh)
  }

  public struct Refused: Error, Sendable, Equatable {
    public var message: String
  }
}
