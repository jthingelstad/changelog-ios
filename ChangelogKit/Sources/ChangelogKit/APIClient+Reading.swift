import Foundation

/// Reading the notes, for a token that may read them all (API 1.15.0), or the
/// notes it wrote. The answers stay in memory: `/v1` sends them `no-store`.
extension APIClient {
  /// The notes on those days, oldest first. `mine` keeps only the notes this
  /// token wrote; `urls` puts each file's address in the answer, for ten
  /// minutes, rather than one read a file.
  public func notes(from: String, to: String? = nil, after: String? = nil, limit: Int = 100,
                    mine: Bool = false, urls: Bool = false) async throws(APIError) -> NoteList {
    var query = [URLQueryItem(name: "from", value: from), URLQueryItem(name: "limit", value: String(limit))]
    if let to { query.append(URLQueryItem(name: "to", value: to)) }
    if let after { query.append(URLQueryItem(name: "after", value: after)) }
    if mine { query.append(URLQueryItem(name: "mine", value: "true")) }
    if urls { query.append(URLQueryItem(name: "include", value: "urls")) }
    return try await send("GET", "v1/notes", query: query)
  }

  /// The timeline, newest first: days with notes, an email, a pause or a place.
  public func days(before: String? = nil, limit: Int = 30) async throws(APIError) -> DayList {
    var query = [URLQueryItem(name: "limit", value: String(limit))]
    if let before { query.append(URLQueryItem(name: "before", value: before)) }
    return try await send("GET", "v1/days", query: query)
  }

  /// One day, and its first notes; `next` goes on through `notes(after:)`.
  public func day(_ date: String, urls: Bool = false) async throws(APIError) -> DayDetail {
    try await send("GET", "v1/days/\(date)", query: urls ? [URLQueryItem(name: "include", value: "urls")] : [])
  }

  /// Every note with all the words, or with a tag, across the whole archive,
  /// newest first; `next` goes on through `after`.
  public func search(_ search: NoteSearch, after: String? = nil, limit: Int = 30,
                     urls: Bool = false) async throws(APIError) -> SearchResults {
    var query = [URLQueryItem(name: "limit", value: String(limit))]
    switch search {
    case .words(let words): query.append(URLQueryItem(name: "q", value: words))
    case .tag(let tag): query.append(URLQueryItem(name: "tag", value: tag))
    }
    if let after { query.append(URLQueryItem(name: "after", value: after)) }
    if urls { query.append(URLQueryItem(name: "include", value: "urls")) }
    return try await send("GET", "v1/search", query: query)
  }

  /// The same day in earlier years, newest first, each with its first notes;
  /// `next` goes on through `before`. Left out, `date` is the account's today.
  public func onThisDay(date: String? = nil, before: String? = nil, limit: Int = 10,
                        urls: Bool = false) async throws(APIError) -> OnThisDay {
    var query = [URLQueryItem(name: "limit", value: String(limit))]
    if let date { query.append(URLQueryItem(name: "date", value: date)) }
    if let before { query.append(URLQueryItem(name: "before", value: before)) }
    if urls { query.append(URLQueryItem(name: "include", value: "urls")) }
    return try await send("GET", "v1/on-this-day", query: query)
  }

  /// A fresh address for one of a note's files, or for its small copy.
  public func fileAddress(date: String, id: String, n: Int, thumb: Bool = false) async throws(APIError) -> FileAddress {
    try await send("GET", "v1/notes/\(date)/\(id)/media/\(n)", query: thumb ? [URLQueryItem(name: "size", value: "thumb")] : [])
  }
}
