import Foundation
import Security

/// Where the token lives between launches. The app uses the Keychain; tests
/// and previews use memory. The token is never written anywhere else.
public protocol TokenStore: Sendable {
  func read() -> String?
  func write(_ token: String) throws
  func clear()
}

/// A token as Release Notes makes it: `rn_` and 43 base64url characters.
public enum TokenFormat {
  public static func looksValid(_ raw: String) -> Bool {
    let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard token.hasPrefix("rn_"), token.count == 46 else { return false }
    return token.dropFirst(3).allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
  }

  /// Pulls a token out of what was pasted (a bare token, or text
  /// around one), so a copied line works as well as the token alone.
  public static func extract(_ raw: String) -> String? {
    let pattern = /rn_[A-Za-z0-9_-]{43}(?![A-Za-z0-9_-])/
    return raw.firstMatch(of: pattern).map { String($0.output) }
  }
}

/// The token in the Keychain. With `accessGroup` (the App Group) it is kept
/// where the share extension can read it too; a build without the group
/// keeps it in the app's own.
public final class KeychainTokenStore: TokenStore {
  private let service: String
  private let accessGroup: String?
  private let account = "release-notes-token"

  public init(service: String = "com.yourversionnumber.changelog", accessGroup: String? = nil) {
    self.service = service
    self.accessGroup = accessGroup
  }

  private var query: [String: Any] {
    [kSecClass as String: kSecClassGenericPassword,
     kSecAttrService as String: service,
     kSecAttrAccount as String: account]
  }

  /// Reads it from any group this app may read: the shared one, or the
  /// app's own, where 0.1 kept it.
  public func read() -> String? {
    var q = query
    q[kSecReturnData as String] = true
    q[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
    return String(data: data, encoding: .utf8)
  }

  public func write(_ token: String) throws {
    clear()
    if let accessGroup {
      let status = add(token, group: accessGroup)
      if status == errSecSuccess { return }
      // A build without the App Group keeps it in the app's own group.
      guard status == errSecMissingEntitlement else { throw KeychainError(status: status) }
    }
    let status = add(token, group: nil)
    guard status == errSecSuccess else { throw KeychainError(status: status) }
  }

  /// Moves a token 0.1 kept in the app's own group to the shared one, so
  /// the share extension can read it. The shared copy is made before the
  /// old one goes, so a failure leaves the token where it was.
  public func share() {
    guard let accessGroup else { return }
    var q = query
    q[kSecReturnAttributes as String] = true
    q[kSecMatchLimit as String] = kSecMatchLimitAll
    var found: CFTypeRef?
    guard SecItemCopyMatching(q as CFDictionary, &found) == errSecSuccess, let items = found as? [[String: Any]] else { return }
    let groups = items.compactMap { $0[kSecAttrAccessGroup as String] as? String }
    guard !groups.isEmpty, !groups.contains(accessGroup), let token = read(),
          add(token, group: accessGroup) == errSecSuccess else { return }
    for group in groups {
      var old = query
      old[kSecAttrAccessGroup as String] = group
      SecItemDelete(old as CFDictionary)
    }
  }

  private func add(_ token: String, group: String?) -> OSStatus {
    var q = query
    q[kSecValueData as String] = Data(token.utf8)
    if let group { q[kSecAttrAccessGroup as String] = group }
    // Readable by background refresh after the first unlock, never synced
    // to other devices or restored onto a new phone.
    q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    return SecItemAdd(q as CFDictionary, nil)
  }

  /// Removes it from every group this app may reach.
  public func clear() {
    SecItemDelete(query as CFDictionary)
  }
}

public struct KeychainError: Error, Equatable {
  public var status: OSStatus
}

public final class MemoryTokenStore: TokenStore, @unchecked Sendable {
  private let lock = NSLock()
  private var token: String?

  public init(_ token: String? = nil) { self.token = token }
  public func read() -> String? { lock.withLock { token } }
  public func write(_ token: String) throws { lock.withLock { self.token = token } }
  public func clear() { lock.withLock { token = nil } }
}
