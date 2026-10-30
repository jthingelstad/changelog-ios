import CryptoKit
import Foundation

/// Signing in with Release Notes: OAuth with PKCE for a native app (RFC
/// 8252), as Phase 5 of Release Notes' `docs/API.md` sets out. The app
/// registers itself, the owner names the token and chooses what it may do and
/// when it ends on Release Notes' own page, and the code that comes back is
/// spent once for an ordinary API token, kept as a pasted one is. There is no
/// refresh token: the token lasts as long as the owner chose.
public struct SignIn: Sendable {
  /// The app's own scheme, which the sign-in sheet watches for.
  public static let callbackScheme = "com.yourversionnumber.changelog"
  public static let redirectURI = callbackScheme + ":/oauth"
  /// Everything the app does, pre-ticked on the page for the owner to
  /// narrow. Never `notes:read`: it reads back only the notes it sent.
  public static let scopes = ["notes:write", "media:write", "upcoming", "activity"]

  public var server: URL
  public var userAgent: String
  public var session: URLSession
  /// Proves the code is spent by the app that asked for it.
  public var verifier: String
  /// Proves the answer is to this sign-in.
  public var state: String

  public init(server: URL, userAgent: String, session: URLSession = .shared,
              verifier: String = SignIn.random(), state: String = SignIn.random()) {
    self.server = server
    self.userAgent = userAgent
    self.session = session
    self.verifier = verifier
    self.state = state
  }

  /// 32 random bytes as base64url: 43 characters.
  public static func random() -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    precondition(status == errSecSuccess, "No random bytes")
    return base64url(Data(bytes))
  }

  static func base64url(_ data: Data) -> String {
    data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  public var challenge: String { Self.base64url(Data(SHA256.hash(data: Data(verifier.utf8)))) }

  /// What the token opens: the server's origin and `/v1`, as the server
  /// names it (`/.well-known/oauth-protected-resource/v1`).
  public var resource: String {
    var origin = URLComponents()
    origin.scheme = server.scheme
    origin.host = server.host()
    origin.port = server.port
    return (origin.string ?? server.absoluteString) + "/v1"
  }

  // MARK: The steps

  /// Registers the app (RFC 7591) and answers its client id. Each sign-in
  /// registers afresh: a sign-in is rare, a registration lasts a year, and
  /// so nothing is kept between them.
  public func register() async throws(SignInError) -> String {
    struct Body: Encodable { var clientName: String; var redirectUris: [String]; var grantTypes: [String] }
    struct Answer: Decodable { var clientId: String }
    var request = URLRequest(url: server.appending(path: "oauth/register"))
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try? APIClient.encoder.encode(
      Body(clientName: "Changelog", redirectUris: [Self.redirectURI], grantTypes: ["authorization_code"]))
    let answer: Answer = try await send(request)
    return answer.clientId
  }

  /// The page the sign-in sheet opens: Release Notes asks the owner to sign
  /// in there if they aren't, then shows what Changelog asks for.
  public func authorizeURL(clientID: String) -> URL {
    server.appending(path: "oauth/authorize").appending(queryItems: [
      URLQueryItem(name: "response_type", value: "code"),
      URLQueryItem(name: "client_id", value: clientID),
      URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
      URLQueryItem(name: "scope", value: Self.scopes.joined(separator: " ")),
      URLQueryItem(name: "state", value: state),
      URLQueryItem(name: "code_challenge", value: challenge),
      URLQueryItem(name: "code_challenge_method", value: "S256"),
      URLQueryItem(name: "resource", value: resource),
    ])
  }

  /// The code the sheet came back with, once its state is this sign-in's.
  /// Nil when the owner chose Cancel on the page: nothing to tell them.
  public func code(from callback: URL) throws(SignInError) -> String? {
    guard callback.scheme == Self.callbackScheme,
          let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems
    else { throw .unreadable }
    func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
    guard value("state") == state else { throw .wrongState }
    if let code = value("code"), !code.isEmpty { return code }
    if value("error") == "access_denied" { return nil }
    throw .refused(value("error") ?? "unknown")
  }

  /// Spends the code for the token. It is spent once: a second try is
  /// refused, and ends the token the first made.
  public func exchange(code: String, clientID: String) async throws(SignInError) -> Grant {
    let form = [
      ("grant_type", "authorization_code"),
      ("code", code),
      ("client_id", clientID),
      ("redirect_uri", Self.redirectURI),
      ("resource", resource),
      ("code_verifier", verifier),
    ]
    var request = URLRequest(url: server.appending(path: "oauth/token"))
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.httpBody = Data(form.map { "\(Self.formEncode($0))=\(Self.formEncode($1))" }.joined(separator: "&").utf8)
    let grant: Grant = try await send(request)
    guard grant.tokenType.lowercased() == "bearer", TokenFormat.looksValid(grant.accessToken) else { throw .unreadable }
    return grant
  }

  /// What the code was spent for. `expiresIn` is nil for a token that never
  /// ends.
  public struct Grant: Decodable, Sendable, Equatable {
    public var accessToken: String
    public var tokenType: String
    public var scope: String
    public var expiresIn: Int?
  }

  // MARK: Transport

  /// An OAuth refusal: `{"error": "invalid_grant"}`.
  private struct Problem: Decodable { var error: String }

  /// Form encoding leaves only the unreserved characters bare, so a `+` is
  /// never read as a space.
  static func formEncode(_ value: String) -> String {
    value.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn:
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")) ?? ""
  }

  private func send<T: Decodable>(_ request: URLRequest) async throws(SignInError) -> T {
    var request = request
    request.timeoutInterval = 30
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    request.httpShouldHandleCookies = false
    let answer: (Data, URLResponse)
    do { answer = try await session.data(for: request) } catch {
      throw .network(error.localizedDescription)
    }
    guard let http = answer.1 as? HTTPURLResponse else { throw .unreadable }
    guard (200..<300).contains(http.statusCode) else {
      throw .refused((try? APIClient.decoder.decode(Problem.self, from: answer.0))?.error ?? "http_\(http.statusCode)")
    }
    do { return try APIClient.decoder.decode(T.self, from: answer.0) } catch { throw .unreadable }
  }
}

/// Why a sign-in with Release Notes didn't finish. None carries a code or a
/// token.
public enum SignInError: Error, Sendable, Equatable {
  /// No answer came (offline, timed out).
  case network(String)
  /// The answer's state isn't this sign-in's: it was never spent.
  case wrongState
  /// Release Notes said no, with an OAuth error code.
  case refused(String)
  case unreadable

  public var message: String {
    switch self {
    case .network(let message): message
    case .wrongState: "That answer wasn't to this sign-in. Try again."
    case .refused("invalid_grant"): "The sign-in ran out of time. Try again."
    case .refused("rate_limited"): "Too many sign-ins just now. Try again later."
    case .refused("temporarily_unavailable"): "Release Notes is busy. Try again in a moment."
    case .refused: "Release Notes didn't sign Changelog in. Try again, or use a token."
    case .unreadable: "Release Notes answered in a way this version doesn't understand."
    }
  }
}
