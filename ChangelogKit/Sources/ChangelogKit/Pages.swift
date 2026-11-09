import Foundation

/// A list `/v1` gives a page at a time, read from the first page on, each
/// with the cursor the page before it gave.
public enum Pages {
  /// Reads page after page until one has no cursor, until `take` has what it
  /// wants (it says false), or until a cursor comes again that was already
  /// read: a server handing back the same page would otherwise be read for
  /// ever. It runs where it is called from, so `take` can fill in a screen
  /// as each page comes.
  public static func read<Page, Failure: Error>(
    isolation: isolated (any Actor)? = #isolation,
    _ fetch: (String?) async throws(Failure) -> Page,
    next: (Page) -> String?,
    take: (Page) -> Bool
  ) async throws(Failure) {
    var cursor: String?
    var read: Set<String> = []
    while true {
      let page = try await fetch(cursor)
      guard take(page), let after = next(page), read.insert(after).inserted else { return }
      cursor = after
    }
  }
}
