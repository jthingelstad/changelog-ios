import Foundation

/// What went wrong with a request, sorted by what the app should do next.
public struct APIError: Error, Sendable, Equatable {
  /// The HTTP status, or 0 when no answer came (offline, timed out).
  public var status: Int
  /// The API's stable code (`scope_required`, `rate_limited`, ...), or
  /// `network` and `unreadable` for failures with no API answer.
  public var code: String
  public var message: String
  public var field: String?
  /// The note's current revision, with `revision_mismatch`.
  public var revision: String?
  public var retryAfter: TimeInterval?

  /// The token no longer works: sign out and ask for a new one.
  public var signedOut: Bool { status == 401 }

  /// Worth sending again later with the same idempotency key.
  public var retryable: Bool {
    status == 0 || status == 429 || status >= 500 || code == "busy"
  }

  static func network(_ error: Error) -> APIError {
    APIError(status: 0, code: "network", message: error.localizedDescription)
  }
}

/// A client of `/v1`. It holds the token only in memory; the app keeps it in
/// the Keychain. The token is never logged or put in a URL.
public struct APIClient: Sendable {
  public static let production = URL(string: "https://notes.yourversionnumber.com")!
  /// `tools/dev-server.ts` in the Release Notes repo, against its fictional
  /// account. The simulator reaches the Mac's localhost.
  public static let devServer = URL(string: "http://localhost:8790")!

  public var baseURL: URL
  public var token: String
  public var userAgent: String
  public var session: URLSession

  public init(baseURL: URL = APIClient.production, token: String, userAgent: String, session: URLSession = .shared) {
    self.baseURL = baseURL
    self.token = token
    self.userAgent = userAgent
    self.session = session
  }

  // MARK: Endpoints

  public func me() async throws(APIError) -> Me {
    try await send("GET", "v1/me")
  }

  public func createNote(_ note: NoteRequest, idempotencyKey: String) async throws(APIError) -> NoteReceipt {
    try await send("POST", "v1/notes", body: note, idempotencyKey: idempotencyKey, expect: 201)
  }

  public func note(date: String, id: String) async throws(APIError) -> NoteDetail {
    try await send("GET", "v1/notes/\(date)/\(id)")
  }

  public func editNote(date: String, id: String, text: String, revision: String, idempotencyKey: String) async throws(APIError) -> NoteRef {
    struct Body: Encodable { var text: String; var revision: String }
    let answer: Wrapped = try await send("PUT", "v1/notes/\(date)/\(id)", body: Body(text: text, revision: revision), idempotencyKey: idempotencyKey)
    return answer.note
  }

  public func appendNote(date: String, id: String, text: String, idempotencyKey: String) async throws(APIError) -> NoteRef {
    struct Body: Encodable { var text: String }
    let answer: Wrapped = try await send("POST", "v1/notes/\(date)/\(id)/append", body: Body(text: text), idempotencyKey: idempotencyKey)
    return answer.note
  }

  public func deleteNote(date: String, id: String, idempotencyKey: String) async throws(APIError) {
    let _: Empty = try await send("DELETE", "v1/notes/\(date)/\(id)", idempotencyKey: idempotencyKey, expect: 204)
  }

  public func tags() async throws(APIError) -> Tags {
    try await send("GET", "v1/tags")
  }

  public func setPinned(_ pinned: [String], idempotencyKey: String) async throws(APIError) -> Tags {
    struct Body: Encodable { var pinned: [String] }
    return try await send("PUT", "v1/tags/pinned", body: Body(pinned: pinned), idempotencyKey: idempotencyKey)
  }

  public func activity(after: String? = nil, before: String? = nil, kinds: [String] = [], limit: Int = 50) async throws(APIError) -> ActivityPage {
    var query = [URLQueryItem(name: "limit", value: String(limit))]
    if let after { query.append(URLQueryItem(name: "after", value: after)) }
    if let before { query.append(URLQueryItem(name: "before", value: before)) }
    if !kinds.isEmpty { query.append(URLQueryItem(name: "kinds", value: kinds.joined(separator: ","))) }
    return try await send("GET", "v1/activity", query: query)
  }

  /// The reminders each morning brings, from today through `days` ahead.
  /// Needs the `upcoming` scope.
  public func reminders(days: Int = ReminderPlan.days) async throws(APIError) -> Reminders {
    try await send("GET", "v1/upcoming/reminders", query: [URLQueryItem(name: "days", value: String(days))])
  }

  /// Sign out: the token revokes itself.
  public func revokeToken() async throws(APIError) {
    let _: Empty = try await send("DELETE", "v1/token", expect: 204)
  }

  // MARK: Transport

  private struct Wrapped: Decodable { var note: NoteRef }
  private struct Empty: Decodable {}
  private struct NoBody: Encodable {}

  static let decoder: JSONDecoder = {
    let d = JSONDecoder()
    d.keyDecodingStrategy = .convertFromSnakeCase
    return d
  }()
  static let encoder: JSONEncoder = {
    let e = JSONEncoder()
    e.keyEncodingStrategy = .convertToSnakeCase
    e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return e
  }()

  func request(_ method: String, _ path: String, query: [URLQueryItem] = [], body: Data? = nil, idempotencyKey: String? = nil) -> URLRequest {
    var url = baseURL.appending(path: path)
    if !query.isEmpty { url.append(queryItems: query) }
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.timeoutInterval = 30
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    if let idempotencyKey { request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key") }
    if let body {
      request.httpBody = body
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    // No cookie ever rides along: /v1 is bearer only.
    request.httpShouldHandleCookies = false
    return request
  }

  func send<T: Decodable>(_ method: String, _ path: String, query: [URLQueryItem] = [], idempotencyKey: String? = nil, expect: Int = 200) async throws(APIError) -> T {
    try await send(method, path, query: query, body: Optional<NoBody>.none, idempotencyKey: idempotencyKey, expect: expect)
  }

  func send<T: Decodable, B: Encodable>(_ method: String, _ path: String, query: [URLQueryItem] = [], body: B?, idempotencyKey: String? = nil, expect: Int = 200) async throws(APIError) -> T {
    let data: Data?
    do { data = try body.map { try Self.encoder.encode($0) } } catch {
      throw APIError(status: 0, code: "unreadable", message: "The note couldn't be prepared.")
    }
    let answer: (Data, URLResponse)
    do { answer = try await session.data(for: request(method, path, query: query, body: data, idempotencyKey: idempotencyKey)) } catch {
      throw .network(error)
    }
    guard let http = answer.1 as? HTTPURLResponse else {
      throw APIError(status: 0, code: "unreadable", message: "No answer from Release Notes.")
    }
    guard (200..<300).contains(http.statusCode) else { throw Self.error(http, answer.0) }
    if T.self == Empty.self { return Empty() as! T }
    do { return try Self.decoder.decode(T.self, from: answer.0) } catch {
      throw APIError(status: http.statusCode, code: "unreadable", message: "Release Notes answered in a way this version doesn't understand.")
    }
  }

  static func error(_ http: HTTPURLResponse, _ data: Data) -> APIError {
    let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
    if let body = try? decoder.decode(ErrorBody.self, from: data) {
      return APIError(status: http.statusCode, code: body.error.code, message: body.error.message,
                      field: body.error.field, revision: body.error.revision, retryAfter: retryAfter)
    }
    let message = HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
    return APIError(status: http.statusCode, code: http.statusCode >= 500 ? "unavailable" : "http_\(http.statusCode)",
                    message: message, retryAfter: retryAfter)
  }
}
