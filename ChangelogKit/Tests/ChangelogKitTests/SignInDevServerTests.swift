import Foundation
import Testing
@testable import ChangelogKit

/// Stops at the first redirect, so the test sees where the server sends the
/// sign-in sheet.
private final class NoRedirects: NSObject, URLSessionTaskDelegate {
  func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                  newRequest request: URLRequest) async -> URLRequest? { nil }
}

/// Sign-in with Release Notes against the dev server, as far as an agent
/// may go: the server takes the app's registration and its request, and
/// sends the sheet to the consent page. The rest (signing in on the page,
/// the owner's Allow) is the owner's, and the server's own tests.
@Suite(.enabled(if: DevServer.enabled), .serialized)
struct SignInDevServerTests {
  @Test func theServerTakesTheAppsRequest() async throws {
    let session = URLSession(configuration: .ephemeral, delegate: NoRedirects(), delegateQueue: nil)
    let flow = SignIn(server: DevServer.url, userAgent: "Changelog/0.1 (dev tests)", session: session)
    let clientID = try await flow.register()
    let (_, response) = try await session.data(from: flow.authorizeURL(clientID: clientID))
    let http = try #require(response as? HTTPURLResponse)
    #expect(http.statusCode == 303)
    let location = try #require(http.value(forHTTPHeaderField: "Location"))
    #expect(location.hasPrefix(flow.resource.dropLast(3) + "/connect/#request="))
    // A spent-nowhere code is refused, never a token.
    await #expect(throws: SignInError.refused("invalid_grant")) {
      try await flow.exchange(code: SignIn.random(), clientID: clientID)
    }
  }
}
