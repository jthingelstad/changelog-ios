import Foundation
import Testing
@testable import ChangelogKit

/// Swift Testing has a `Tag` of its own; in these tests, `Tag` is a tag of a note.
typealias Tag = ChangelogKit.Tag

/// Release Notes' `contracts/tag-vectors.json`, copied here as it is: how the
/// server reads a name typed into a tags field, what a field refuses, and the
/// tags a note's #words make. Copy it again whenever the server's changes.
@Suite struct TagVectorTests {
  struct Vectors: Decodable {
    struct Name: Decodable { var typed: String; var name: String; var key: String }
    struct Refused: Decodable { var typed: String; var reason: String }
    struct Text: Decodable { var text: String; var tags: [Tag] }
    var names: [Name]
    var refused: [Refused]
    var text: [Text]
    var keysAreStable: Bool
  }

  static let vectors: Vectors = {
    let url = Bundle.module.url(forResource: "tag-vectors", withExtension: "json")!
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return try! decoder.decode(Vectors.self, from: Data(contentsOf: url))
  }()

  @Test func theVectorsAreThere() {
    #expect(Self.vectors.names.count > 30)
    #expect(Self.vectors.refused.count > 5)
    #expect(Self.vectors.keysAreStable)
  }

  @Test(arguments: TagVectorTests.vectors.names.map { ($0.typed, $0.name, $0.key) })
  func spellsANameAsTheServerDoes(typed: String, name: String, key: String) throws {
    #expect(try Hashtags.spelling(typed).get() == Tag(key: key, name: name))
    // A key is its own key, so a key from the server matches itself.
    #expect(Hashtags.key(key) == key)
  }

  @Test(arguments: TagVectorTests.vectors.refused.map { ($0.typed, $0.reason) })
  func refusesWhatTheServerRefuses(typed: String, reason: String) {
    #expect(Hashtags.spelling(typed) == .failure(TagRefusal(rawValue: reason)!))
  }

  @Test(arguments: TagVectorTests.vectors.text.map { ($0.text, $0.tags) })
  func readsHashtagsAsTheServerDoes(text: String, tags: [Tag]) {
    #expect(Hashtags.textTags(text) == tags)
  }
}
