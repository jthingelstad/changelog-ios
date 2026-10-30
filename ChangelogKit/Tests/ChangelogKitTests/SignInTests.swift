import Foundation
import Testing
@testable import ChangelogKit

@Suite struct SignInTests {
  static let verifier = "dBjftJeZ4CVP-mJ0QAg3eaD8c5r7E8PTOWwxSStoAc8"

  func signIn(_ host: String, state: String = "s-1") -> SignIn {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubProtocol.self]
    return SignIn(server: URL(string: "https://\(host)")!, userAgent: "Changelog/0.1 (iOS 26.1)",
                  session: URLSession(configuration: config), verifier: Self.verifier, state: state)
  }

  @Test func theChallengeIsTheVerifiersSHA256() {
    #expect(signIn("pkce.test").challenge == "gajotmTxoXP2wlQJSV-f5kybIRKDjsC5me1TPVJp4gQ")
    let random = SignIn.random()
    #expect(random.count == 43)
    #expect(random.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
    #expect(SignIn.random() != random)
  }

  @Test func theResourceIsTheOriginAndV1() {
    #expect(signIn("notes.test").resource == "https://notes.test/v1")
    let dev = SignIn(server: URL(string: "http://localhost:8790")!, userAgent: "x")
    #expect(dev.resource == "http://localhost:8790/v1")
  }

  @Test func registersTheAppForItsOwnScheme() async throws {
    StubProtocol.set("register.test", .init(status: 201, body: """
      {"client_id":"c-1","client_name":"Changelog","redirect_uris":["com.yourversionnumber.changelog:/oauth"]}
      """))
    #expect(try await signIn("register.test").register() == "c-1")
    let request = try #require(StubProtocol.requests("register.test").first)
    #expect(request.httpMethod == "POST")
    #expect(request.url?.path == "/oauth/register")
    #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    let body = try JSONSerialization.jsonObject(with: try #require(request.httpBody)) as? [String: AnyHashable]
    #expect(body == ["client_name": "Changelog", "redirect_uris": ["com.yourversionnumber.changelog:/oauth"],
                     "grant_types": ["authorization_code"]])
  }

  @Test func asksForEverythingButReadingNotes() throws {
    let url = signIn("notes.test").authorizeURL(clientID: "c-1")
    let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
    let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    #expect(url.path == "/oauth/authorize")
    #expect(query == [
      "response_type": "code", "client_id": "c-1", "redirect_uri": "com.yourversionnumber.changelog:/oauth",
      "scope": "notes:write media:write upcoming activity", "state": "s-1",
      "code_challenge": "gajotmTxoXP2wlQJSV-f5kybIRKDjsC5me1TPVJp4gQ", "code_challenge_method": "S256",
      "resource": "https://notes.test/v1",
    ])
    #expect(!query["scope"]!.contains("notes:read"))
  }

  @Test func takesTheCodeOnlyWithItsState() throws {
    let flow = signIn("notes.test")
    #expect(try flow.code(from: URL(string: "com.yourversionnumber.changelog:/oauth?code=k-9&state=s-1")!) == "k-9")
    // Cancel on the page is no problem to tell of.
    #expect(try flow.code(from: URL(string: "com.yourversionnumber.changelog:/oauth?error=access_denied&state=s-1")!) == nil)
    #expect(throws: SignInError.wrongState) {
      try flow.code(from: URL(string: "com.yourversionnumber.changelog:/oauth?code=k-9&state=other")!)
    }
    #expect(throws: SignInError.wrongState) {
      try flow.code(from: URL(string: "com.yourversionnumber.changelog:/oauth?code=k-9")!)
    }
    #expect(throws: SignInError.refused("invalid_request")) {
      try flow.code(from: URL(string: "com.yourversionnumber.changelog:/oauth?error=invalid_request&state=s-1")!)
    }
    #expect(throws: SignInError.unreadable) {
      try flow.code(from: URL(string: "https://elsewhere.test/oauth?code=k-9&state=s-1")!)
    }
  }

  @Test func spendsTheCodeForAToken() async throws {
    let token = "rn_" + String(repeating: "B", count: 43)
    StubProtocol.set("token.test", .init(status: 200, body: """
      {"access_token":"\(token)","token_type":"Bearer","scope":"notes:write activity","expires_in":31536000}
      """))
    let grant = try await signIn("token.test").exchange(code: "k+9/x", clientID: "c-1")
    #expect(grant == SignIn.Grant(accessToken: token, tokenType: "Bearer", scope: "notes:write activity", expiresIn: 31536000))
    let request = try #require(StubProtocol.requests("token.test").first)
    #expect(request.url?.path == "/oauth/token")
    #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
    let form = String(decoding: try #require(request.httpBody), as: UTF8.self)
    #expect(form == "grant_type=authorization_code&code=k%2B9%2Fx&client_id=c-1"
      + "&redirect_uri=com.yourversionnumber.changelog%3A%2Foauth&resource=https%3A%2F%2Ftoken.test%2Fv1"
      + "&code_verifier=\(Self.verifier)")
  }

  @Test func aTokenThatNeverEndsHasNoExpiry() async throws {
    StubProtocol.set("forever.test", .init(status: 200, body: """
      {"access_token":"rn_\(String(repeating: "C", count: 43))","token_type":"Bearer","scope":"notes:write"}
      """))
    #expect(try await signIn("forever.test").exchange(code: "k", clientID: "c").expiresIn == nil)
  }

  @Test func aSpentCodeIsRefused() async throws {
    StubProtocol.set("spent.test", .init(status: 400, body: #"{"error":"invalid_grant"}"#))
    await #expect(throws: SignInError.refused("invalid_grant")) {
      try await signIn("spent.test").exchange(code: "k", clientID: "c")
    }
    #expect(SignInError.refused("invalid_grant").message == "The sign-in ran out of time. Try again.")
  }

  @Test func anAnswerThatIsNoTokenIsUnreadable() async throws {
    StubProtocol.set("odd.test", .init(status: 200, body: #"{"access_token":"abc","token_type":"Bearer","scope":"notes:write"}"#))
    await #expect(throws: SignInError.unreadable) {
      try await signIn("odd.test").exchange(code: "k", clientID: "c")
    }
  }

  @Test func noAnswerIsANetworkError() async throws {
    await #expect {
      try await signIn("offline.test").register()
    } throws: { error in
      if case .network = error as? SignInError { true } else { false }
    }
  }
}
