import Foundation
import Testing
@testable import ChangelogKit

/// Reading a list a page at a time, to the last.
struct PagesTests {
  struct Page: Equatable {
    var items: [Int]
    var next: String?
  }

  struct Failed: Error, Equatable {}

  /// A server: each cursor's page, and every cursor it was asked for.
  @MainActor final class Server {
    let pages: [String: Page]
    var asked: [String?] = []
    var failAt: String?

    init(_ pages: [String: Page]) { self.pages = pages }

    func page(_ cursor: String?) throws(Failed) -> Page {
      asked.append(cursor)
      if let failAt, cursor == failAt { throw Failed() }
      return pages[cursor ?? ""]!
    }
  }

  @MainActor @Test func everyPageComesInTurnToTheLast() async throws {
    let server = Server(["": Page(items: [1, 2], next: "b"), "b": Page(items: [3], next: "c"), "c": Page(items: [4])])
    var items: [Int] = []
    try await Pages.read({ (cursor) async throws(Failed) in try server.page(cursor) }, next: \.next) { page in
      items += page.items
      return true
    }
    #expect(items == [1, 2, 3, 4])
    #expect(server.asked == [nil, "b", "c"])
  }

  @MainActor @Test func aCursorThatComesBackEndsTheReading() async throws {
    // The same page again, and a loop through two.
    let same = Server(["": Page(items: [1], next: "b"), "b": Page(items: [2], next: "b")])
    var items: [Int] = []
    try await Pages.read({ (cursor) async throws(Failed) in try same.page(cursor) }, next: \.next) { page in
      items += page.items
      return true
    }
    #expect(items == [1, 2])
    #expect(same.asked == [nil, "b"])

    let loop = Server(["": Page(items: [1], next: "b"), "b": Page(items: [2], next: "c"), "c": Page(items: [3], next: "b")])
    items = []
    try await Pages.read({ (cursor) async throws(Failed) in try loop.page(cursor) }, next: \.next) { page in
      items += page.items
      return true
    }
    #expect(items == [1, 2, 3])
    #expect(loop.asked == [nil, "b", "c"])
  }

  @MainActor @Test func itStopsOnceTakeHasWhatItWants() async throws {
    let server = Server(["": Page(items: [1], next: "b"), "b": Page(items: [2], next: "c"), "c": Page(items: [3])])
    var found: Int?
    try await Pages.read({ (cursor) async throws(Failed) in try server.page(cursor) }, next: \.next) { page in
      found = page.items.first { $0 == 2 }
      return found == nil
    }
    #expect(found == 2)
    #expect(server.asked == [nil, "b"])
  }

  @MainActor @Test func aFailedPageEndsItWithItsError() async {
    let server = Server(["": Page(items: [1], next: "b"), "b": Page(items: [2])])
    server.failAt = "b"
    var items: [Int] = []
    await #expect(throws: Failed()) {
      try await Pages.read({ (cursor) async throws(Failed) in try server.page(cursor) }, next: \.next) { page in
        items += page.items
        return true
      }
    }
    #expect(items == [1])
  }
}
