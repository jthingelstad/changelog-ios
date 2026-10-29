import Foundation

/// A date being added or edited on the phone. It keeps a month and day for
/// the yearly kinds and full days for the rest, so switching kind and back
/// loses nothing, and it checks only what the phone can before sending:
/// the server stays the authority (and the one that knows its cities).
public struct UpcomingDraft: Sendable, Equatable {
  public var kind: UpcomingKind {
    // Reminders left at one kind's default follow the new kind's.
    didSet { if reminders == oldValue.defaultReminders { reminders = kind.defaultReminders } }
  }
  public var title = ""
  /// A birthday's or anniversary's month and day.
  public var month = 1 {
    didSet { day = min(day, Self.days(in: month)) }
  }
  public var day = 1 {
    didSet { day = min(max(day, 1), Self.days(in: month)) }
  }
  public var year: Int?
  /// A trip's first day or an event's day, `YYYY-MM-DD`.
  public var start: String {
    didSet { if end < start { end = start } }
  }
  /// A trip's last day.
  public var end: String
  /// A trip's destination, or an event's place.
  public var place = ""
  public var tag = ""
  public var reminders: [Int]
  public var email = true
  /// The account's today, for the year check.
  public private(set) var today: String

  /// What the person can fix before anything is sent. The words never name
  /// the date's own title, day or place.
  public enum Problem: String, Error, Sendable {
    case title = "Give it a title, on one line."
    case titleTooLong = "A title can be at most 120 characters."
    case year = "A year goes with a birthday or anniversary, and can't be after this year."
    case end = "A trip's last day can't be before its first."
    case place = "A trip needs a destination, like Zürich or Paris, Texas."
    case tag = "A tag is one word of letters, numbers and hyphens, like family."
    case reminders = "Choose from one to six reminders, or turn the morning email off."
  }

  public static let titleMax = 120

  public init(kind: UpcomingKind = .birthday, today: String) {
    self.kind = kind
    self.today = today
    start = today
    end = today
    reminders = kind.defaultReminders
    if let (_, m, d) = Self.parse(today) {
      month = m
      day = d
    }
  }

  public init(entry: UpcomingEntry, today: String) {
    let f = entry.fields
    self.init(kind: f.kind, today: today)
    title = f.title
    year = f.year
    place = f.place ?? ""
    tag = f.tag ?? ""
    reminders = f.reminders
    email = f.email
    if f.kind.annual {
      let parts = f.date.split(separator: "-").compactMap { Int($0) }
      if parts.count == 2 {
        month = parts[0]
        day = parts[1]
      }
    } else if Self.parse(f.date) != nil {
      start = f.date
      end = f.endDate.flatMap { Self.parse($0) != nil ? $0 : nil } ?? f.date
    }
  }

  /// The fields to send, or the first thing to fix.
  public func fields() -> Result<UpcomingFields, Problem> {
    let title = self.title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty, !title.contains(where: \.isNewline) else { return .failure(.title) }
    guard title.count <= Self.titleMax else { return .failure(.titleTooLong) }

    var tag: String?
    let typed = self.tag.trimmingCharacters(in: .whitespaces)
    if !typed.isEmpty && typed != "#" {
      guard let normal = Hashtags.normalize(typed) else { return .failure(.tag) }
      tag = normal
    }

    let days = Array(Set(reminders)).filter { (0...365).contains($0) }.sorted(by: >)
    guard (1...6).contains(days.count) else { return .failure(.reminders) }

    let place = self.place.trimmingCharacters(in: .whitespacesAndNewlines)
    switch kind {
    case .birthday, .anniversary:
      if let year, year < 1 || year > (Self.parse(today)?.0 ?? Int.max) { return .failure(.year) }
      let date = String(format: "%02d-%02d", month, min(day, Self.days(in: month)))
      return .success(UpcomingFields(kind: kind, title: title, date: date, year: year, tag: tag, reminders: days, email: email))
    case .trip:
      guard end >= start else { return .failure(.end) }
      guard !place.isEmpty else { return .failure(.place) }
      return .success(UpcomingFields(kind: kind, title: title, date: start, endDate: end, place: place, tag: tag,
                                     reminders: days, email: email))
    case .event:
      return .success(UpcomingFields(kind: kind, title: title, date: start, place: place.isEmpty ? nil : place, tag: tag,
                                     reminders: days, email: email))
    }
  }

  /// The batch to save it: an add, or a change from the revision read.
  public func batch(editing entry: UpcomingEntry?, dryRun: Bool = false) -> Result<UpcomingBatch, Problem> {
    fields().map { fields in
      entry.map { UpcomingBatch.changing($0, to: fields, dryRun: dryRun) } ?? .adding(fields, dryRun: dryRun)
    }
  }

  /// A dry run that only looks up the destination: a title not yet typed
  /// stands in as the kind's name, since nothing is saved.
  public func placeCheck(editing entry: UpcomingEntry?) -> Result<UpcomingBatch, Problem> {
    var probe = self
    if probe.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { probe.title = kind.rawValue.capitalized }
    return probe.batch(editing: entry, dryRun: true)
  }

  /// Days in a month for a yearly date: February has the 29th, which the
  /// server keeps for leap-day birthdays.
  public static func days(in month: Int) -> Int {
    switch month {
    case 2: 29
    case 4, 6, 9, 11: 30
    default: 31
    }
  }

  /// `YYYY-MM-DD` as numbers, or nil.
  public static func parse(_ day: String) -> (Int, Int, Int)? {
    let parts = day.split(separator: "-", omittingEmptySubsequences: false)
    guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
          let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
          (1...12).contains(m), (1...31).contains(d) else { return nil }
    return (y, m, d)
  }
}
