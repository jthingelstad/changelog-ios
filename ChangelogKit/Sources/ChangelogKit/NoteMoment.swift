import Foundation

/// A moment's values as `/v1` keeps them beside a note's words (API 1.5.0,
/// `docs/MOMENTS.md` in jthingelstad/yvn-release-notes): the typed pieces a
/// pick held, sent once with a new note and kept as picked. The words stay
/// the note; these say the same things as values. Encoded through
/// `APIClient`'s encoder, so `distanceM` goes as `distance_m`, and a field
/// that is nil isn't sent.
public struct NoteMoment: Codable, Sendable, Equatable {
  /// When the moment began, RFC 3339.
  public var at: String?
  public var items: [Item]

  public init(at: String? = nil, items: [Item]) {
    self.at = at
    self.items = items
  }

  /// At most this many pieces a moment, as Release Notes takes them.
  public static let maxItems = 12
  /// A name, title or place, in code points.
  static let maxWords = 200
  /// A reflection prompt, in code points.
  static let maxPrompt = 400
  static let maxLabels = 10
  static let maxLabel = 40
  static let maxPeople = 20
  /// A workout of up to 1,000 km and a week; a day of up to a million steps.
  static let maxMeters = 1_000_000.0
  static let maxSeconds = 7 * 86400.0
  static let maxSteps = 1_000_000

  /// One piece. `kind` says which fields it has; the rest stay nil, and
  /// Release Notes refuses a field that isn't its kind's.
  public struct Item: Codable, Sendable, Equatable {
    /// workout, song, podcast, played, steps, feeling, event, people or
    /// reflection.
    public var kind: String
    /// A workout's: walking, running, cycling, hiking, swimming or other.
    public var activity: String?
    /// A workout's own name ("Yoga").
    public var name: String?
    public var distanceM: Double?
    public var durationS: Double?
    /// A song's, something played's, or an event's.
    public var title: String?
    public var artist: String?
    public var episode: String?
    public var show: String?
    /// Steps.
    public var count: Int?
    /// walking, running or both.
    public var movement: String?
    /// A feeling's words ("calm"), and how pleasant it was (`slightly_pleasant`).
    public var labels: [String]?
    public var valence: String?
    /// An event's.
    public var place: String?
    public var start: String?
    public var hosted: Bool?
    /// Who was there.
    public var names: [String]?
    /// A reflection's prompt, as Apple words it.
    public var prompt: String?

    public init(kind: String, activity: String? = nil, name: String? = nil, distanceM: Double? = nil, durationS: Double? = nil,
                title: String? = nil, artist: String? = nil, episode: String? = nil, show: String? = nil, count: Int? = nil,
                movement: String? = nil, labels: [String]? = nil, valence: String? = nil, place: String? = nil,
                start: String? = nil, hosted: Bool? = nil, names: [String]? = nil, prompt: String? = nil) {
      self.kind = kind
      self.activity = activity
      self.name = name
      self.distanceM = distanceM
      self.durationS = durationS
      self.title = title
      self.artist = artist
      self.episode = episode
      self.show = show
      self.count = count
      self.movement = movement
      self.labels = labels
      self.valence = valence
      self.place = place
      self.start = start
      self.hosted = hosted
      self.names = names
      self.prompt = prompt
    }
  }
}

/// A moment's values waiting in the draft, each piece with the line it
/// wrote there. The draft is still the person's to shape: at Commit only
/// the pieces whose line is still in the words go, so a line deleted takes
/// its piece with it.
public struct MomentValues: Codable, Sendable, Equatable {
  public var at: String?
  public var pieces: [Piece]

  public struct Piece: Codable, Sendable, Equatable {
    /// The line this piece put in the draft.
    public var line: String
    public var item: NoteMoment.Item

    public init(line: String, item: NoteMoment.Item) {
      self.line = line
      self.item = item
    }
  }

  public init(at: String? = nil, pieces: [Piece]) {
    self.at = at
    self.pieces = pieces
  }

  /// What goes with a note whose words are `text`: the pieces whose line
  /// is still in them, up to the twelve Release Notes takes; nil when none is.
  public func kept(in text: String) -> NoteMoment? {
    let items = pieces.filter { text.contains($0.line) }.map(\.item)
    return items.isEmpty ? nil : NoteMoment(at: at, items: Array(items.prefix(NoteMoment.maxItems)))
  }

  /// A second moment picked into the same draft: its pieces after these,
  /// none twice, and the earlier start.
  public func adding(_ other: MomentValues) -> MomentValues {
    var out = self
    for piece in other.pieces where !out.pieces.contains(piece) { out.pieces.append(piece) }
    switch (at.flatMap(Self.date), other.at.flatMap(Self.date)) {
    case let (mine?, theirs?): out.at = theirs < mine ? other.at : at
    case (nil, _?): out.at = other.at
    default: break
    }
    return out
  }

  private static func date(_ text: String) -> Date? { try? Date(text, strategy: .iso8601) }
}

extension Moment {
  /// The value a piece is sent as, tidied as Release Notes tidies it, or
  /// nil when nothing of it would be taken (the line still goes in the
  /// words). Photos, videos, places and people aren't pieces here: photos
  /// are files, a place is the note's place, and people are one piece for
  /// the moment.
  static func item(_ piece: Piece, timeZone: TimeZone) -> NoteMoment.Item? {
    switch piece {
    case .workout(let workout):
      let activity = switch workout.activity {
      case .walking: "walking"
      case .running: "running"
      case .cycling: "cycling"
      case .hiking: "hiking"
      case .swimming: "swimming"
      case .other: "other"
      }
      return NoteMoment.Item(kind: "workout", activity: activity, name: fit(workout.name),
                             distanceM: amount(workout.meters, max: NoteMoment.maxMeters),
                             durationS: amount(workout.seconds, max: NoteMoment.maxSeconds))
    case .song(let title, let artist), .played(let title, let artist):
      let kind = if case .song = piece { "song" } else { "played" }
      let title = fit(title), artist = fit(artist)
      guard title != nil || artist != nil else { return nil }
      return NoteMoment.Item(kind: kind, title: title, artist: artist)
    case .podcast(let episode, let show):
      let episode = fit(episode), show = fit(show)
      guard episode != nil || show != nil else { return nil }
      return NoteMoment.Item(kind: "podcast", episode: episode, show: show)
    case .steps(let steps, let movement):
      guard (1...NoteMoment.maxSteps).contains(steps) else { return nil }
      let movement: String? = switch movement {
      case .walking: "walking"
      case .running: "running"
      case .both: "both"
      case nil: nil
      }
      return NoteMoment.Item(kind: "steps", count: steps, movement: movement)
    case .feeling(let feeling):
      var labels: [String] = []
      for label in feeling.labels.compactMap({ fit($0, max: NoteMoment.maxLabel) }) where !labels.contains(label) {
        labels.append(label)
      }
      labels = Array(labels.prefix(NoteMoment.maxLabels))
      let valence = fit(feeling.valence).map { $0.lowercased().replacingOccurrences(of: " ", with: "_") }
        .flatMap { Self.valences.contains($0) ? $0 : nil }
      guard !labels.isEmpty || valence != nil else { return nil }
      return NoteMoment.Item(kind: "feeling", labels: labels.isEmpty ? nil : labels, valence: valence)
    case .event(let title, let place, let start, let hosted):
      guard let title = fit(title) else { return nil }
      return NoteMoment.Item(kind: "event", title: title, place: fit(place),
                             start: start.map { Timestamp.string($0, timeZone: timeZone) }, hosted: hosted)
    case .reflection(let prompt):
      return fit(prompt, max: NoteMoment.maxPrompt).map { NoteMoment.Item(kind: "reflection", prompt: $0) }
    case .photo, .video, .place, .person:
      return nil
    }
  }

  /// Who was there, as one piece: up to the twenty names Release Notes takes.
  static func people(_ names: [String]) -> NoteMoment.Item? {
    var kept: [String] = []
    for name in names.compactMap({ fit($0) }) where !kept.contains(name) { kept.append(name) }
    return kept.isEmpty ? nil : NoteMoment.Item(kind: "people", names: Array(kept.prefix(NoteMoment.maxPeople)))
  }

  /// Health's valence, as Release Notes names it.
  static let valences: Set<String> = ["very_unpleasant", "unpleasant", "slightly_unpleasant", "neutral",
                                      "slightly_pleasant", "pleasant", "very_pleasant"]

  /// The words with each run of spaces one space, trimmed, as Release Notes
  /// keeps them; nil when there are none, or more than `max` code points,
  /// which it would refuse.
  static func fit(_ text: String?, max: Int = NoteMoment.maxWords) -> String? {
    guard let text else { return nil }
    let tidied = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    return tidied.isEmpty || tidied.unicodeScalars.count > max ? nil : tidied
  }

  /// A distance or a time to tenths, as Release Notes keeps it; nil when
  /// there is none or it is out of range.
  static func amount(_ value: Double?, max: Double) -> Double? {
    guard let value, value.isFinite, value <= max else { return nil }
    let tenths = (value * 10).rounded() / 10
    return tenths > 0 ? tenths : nil
  }
}
