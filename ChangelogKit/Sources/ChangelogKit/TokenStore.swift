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

  /// Pulls a token out of what was pasted or scanned (a bare token, or text
  /// around one), so a copied line works as well as the token alone.
  public static func extract(_ raw: String) -> String? {
    let pattern = /rn_[A-Za-z0-9_-]{43}(?![A-Za-z0-9_-])/
    return raw.firstMatch(of: pattern).map { String($0.output) }
  }
}

public final class KeychainTokenStore: TokenStore {
  private let service: String
  private let account = "release-notes-token"

  public init(service: String = "com.thingelstad.changelog") {
    self.service = service
  }

  private var query: [String: Any] {
    [kSecClass as String: kSecClassGenericPassword,
     kSecAttrService as String: service,
     kSecAttrAccount as String: account]
  }

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
    var q = query
    q[kSecValueData as String] = Data(token.utf8)
    // Readable by background refresh after the first unlock, never synced
    // to other devices or restored onto a new phone.
    q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    let status = SecItemAdd(q as CFDictionary, nil)
    guard status == errSecSuccess else { throw KeychainError(status: status) }
  }

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
