import Foundation

/// The Upcoming calls, all needing the `upcoming` scope. Writes carry an
/// `Idempotency-Key` (see `RequestKey`), so a Save tapped again after a lost
/// answer is the same save, never a second date.
public extension APIClient {
  /// Every date ahead, soonest first, each with the server's own line.
  func upcoming() async throws(APIError) -> UpcomingList {
    try await send("GET", "v1/upcoming")
  }

  /// Adds, changes and removes dates, all or nothing. A refusal's `field`
  /// names the entry (`add[0]`); `revision_mismatch` means read the list
  /// again. A dry run saves nothing and needs no key.
  func saveUpcoming(_ batch: UpcomingBatch, idempotencyKey: String?) async throws(APIError) -> UpcomingSaved {
    try await send("POST", "v1/upcoming/batch", body: batch, idempotencyKey: idempotencyKey)
  }

  /// Removes one date, from the revision read.
  func deleteUpcoming(id: String, revision: Int, idempotencyKey: String) async throws(APIError) {
    let _: Empty = try await send("DELETE", "v1/upcoming/\(id)",
                                  query: [URLQueryItem(name: "revision", value: String(revision))],
                                  idempotencyKey: idempotencyKey, expect: 204)
  }
}

/// The `Idempotency-Key` for a write sent at once rather than queued: the
/// same key for as long as the same request is tried again, a new one as
/// soon as it changes (the server refuses a key that went with a different
/// request). So an answer lost on a bad connection is safe to try again.
public struct RequestKey<Request: Equatable & Sendable>: Sendable {
  private var request: Request?
  private var current = ""

  public init() {}

  public mutating func key(for request: Request, make: () -> String = { UUID().uuidString.lowercased() }) -> String {
    if request != self.request || current.isEmpty {
      self.request = request
      current = make()
    }
    return current
  }

  /// A request was tried and isn't known to have landed or been refused: its
  /// answer may have been lost.
  public var pending: Bool { !current.isEmpty }

  /// Once a request has landed, the next one is new even if it looks alike.
  public mutating func reset() {
    request = nil
    current = ""
  }
}
