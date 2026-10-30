import Foundation

/// The words a share brings, from each item's own text and its links and
/// plain-text attachments, in order. Apps that hand over a passage twice,
/// as the item's text and again as a plain-text attachment (Notes, a
/// selection in Safari), file it once.
public enum SharedWords {
  public static func joined(_ passages: [String]) -> String {
    var seen = Set<String>()
    return passages
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty && seen.insert(plain($0)).inserted }
      .joined(separator: "\n")
  }

  /// A passage as compared: its words, whatever spaces and line breaks
  /// fall between them.
  static func plain(_ passage: String) -> String {
    passage.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
  }
}
