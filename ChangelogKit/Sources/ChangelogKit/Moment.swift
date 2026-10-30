import Foundation

/// A moment picked in Apple's Journaling Suggestions picker (Moments, in
/// Log), as plain values. The app reads the framework's types into this,
/// on a phone only (the simulator has no framework); what a moment puts in
/// the draft is worked out here, so it is tested without the framework.
/// Every line is written by these rules alone, never by a model, and
/// nothing a moment brings is sent until the person commits the draft.
public struct Moment: Sendable, Equatable {
  /// When the moment began; it files to that day.
  public var date: Date?
  /// What it holds, in the picker's order.
  public var pieces: [Piece]

  public init(date: Date?, pieces: [Piece]) {
    self.date = date
    self.pieces = pieces
  }

  public enum Piece: Sendable, Equatable {
    /// A photo, or a Live Photo's still: a file the picker handed over.
    case photo(URL)
    /// A video, which Release Notes doesn't keep.
    case video
    /// A place visited: its coordinates for Here to name, else its name.
    case place(Spot?, name: String?)
    case workout(Workout)
    case song(title: String?, artist: String?)
    case podcast(episode: String?, show: String?)
    /// Something listened to in another app.
    case played(title: String?, artist: String?)
    case steps(Int, Movement?)
    /// A State of Mind logged in Health.
    case feeling(Feeling)
    /// An Apple Invites event.
    case event(title: String, place: String?, start: Date?, hosted: Bool)
    case person(String)
    /// A reflection prompt, as Apple words it.
    case reflection(String)
  }

  public struct Workout: Sendable, Equatable {
    public enum Activity: Sendable, Equatable { case walking, running, cycling, hiking, swimming, other }

    public var activity: Activity
    /// Apple's name for it ("Yoga"), for an activity without a verb here.
    public var name: String?
    public var meters: Double?
    public var seconds: TimeInterval?

    public init(activity: Activity, name: String? = nil, meters: Double? = nil, seconds: TimeInterval? = nil) {
      self.activity = activity
      self.name = name
      self.meters = meters
      self.seconds = seconds
    }
  }

  public enum Movement: Sendable, Equatable { case walking, running, both }

  public struct Feeling: Sendable, Equatable {
    /// Health's words for it ("calm", "grateful"), lower case.
    public var labels: [String]
    /// How pleasant it was, in Health's words ("slightly pleasant"), for a
    /// State of Mind with no labels.
    public var valence: String?

    public init(labels: [String], valence: String? = nil) {
      self.labels = labels
      self.valence = valence
    }
  }
}

/// What a moment puts in the draft. The person edits it and commits as
/// usual, through the Outbox.
public struct MomentDraft: Sendable, Equatable {
  /// One plain line each, for the box.
  public var lines: [String] = []
  /// Photos to add as the photo picker's are, within the draft's room.
  public var photos: [URL] = []
  /// The place visited, for Here to name: one lookup a pick.
  public var spot: Spot?
  /// The day the note files to; nil for today.
  public var day: String?
  /// What the person is told and the note doesn't say (a video left out).
  public var notice: String?

  public var isEmpty: Bool { lines.isEmpty && photos.isEmpty && spot == nil }
}

public extension Moment {
  /// What this moment puts in a draft that has `room` files to go, on a
  /// day that is `today` in the account's `timeZone`. A moment from today,
  /// or from later (an event ahead), files to today. One from before the
  /// birthday, which the app never learns, is sent with its day, and the
  /// Outbox files it to today when Release Notes refuses that day.
  func draft(today: String, timeZone: TimeZone, room: Int, canAddFiles: Bool, now: Date = .now,
             locale: Locale = .autoupdatingCurrent) -> MomentDraft {
    var out = MomentDraft()
    var photos: [URL] = []
    var videos = 0
    var people: [String] = []
    var peopleAt: Int?
    for piece in pieces {
      switch piece {
      case .photo(let url): photos.append(url)
      case .video: videos += 1
      case .place(let spot, let name):
        if let spot {
          if out.spot == nil { out.spot = spot }
        } else if let name = Self.words(name) {
          out.add("At \(name)")
        }
      case .person(let name):
        guard let name = Self.words(name) else { continue }
        if peopleAt == nil { peopleAt = out.lines.count }
        if !people.contains(name) { people.append(name) }
      default:
        if let line = Self.line(piece, now: now, locale: locale) { out.add(line) }
      }
    }
    if let peopleAt { out.lines.insert("With " + people.formatted(.list(type: .and).locale(locale)), at: peopleAt) }

    var notices: [String] = []
    if !photos.isEmpty && !canAddFiles {
      notices.append(photos.count == 1
        ? "This token can't add files, so the moment's photo isn't on this note."
        : "This token can't add files, so the moment's \(photos.count) photos aren't on this note.")
    } else {
      out.photos = Array(photos.prefix(max(0, room)))
      let over = photos.count - out.photos.count
      if over > 0 {
        notices.append(over == 1
          ? "A note holds up to \(MediaType.maxFiles) files, so one of the moment's photos isn't on it."
          : "A note holds up to \(MediaType.maxFiles) files, so \(over) of the moment's photos aren't on it.")
      }
    }
    if videos > 0 {
      notices.append(videos == 1
        ? "Release Notes doesn't keep video, so the moment's video isn't on this note."
        : "Release Notes doesn't keep video, so the moment's \(videos) videos aren't on this note.")
    }
    if out.isEmpty && notices.isEmpty { notices.append("That moment has nothing Changelog can put on a note.") }
    out.notice = notices.isEmpty ? nil : notices.joined(separator: " ")
    if !out.isEmpty, let date, let day = Self.day(of: date, in: timeZone), day < today { out.day = day }
    return out
  }

  /// The local day of `date` in `zone`, as `/v1` writes days.
  static func day(of date: Date, in zone: TimeZone) -> String? {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    let parts = calendar.dateComponents([.year, .month, .day], from: date)
    guard let year = parts.year, let month = parts.month, let day = parts.day else { return nil }
    return String(format: "%04d-%02d-%02d", year, month, day)
  }

  /// The one line a piece becomes, or nil when it says nothing.
  internal static func line(_ piece: Piece, now: Date, locale: Locale) -> String? {
    switch piece {
    case .workout(let workout): return line(workout, locale: locale)
    case .song(let title, let artist), .played(let title, let artist):
      return listened(words(title), by: words(artist))
    case .podcast(let episode, let show):
      switch (words(episode), words(show)) {
      case let (episode?, show?): return "Listened to \(episode) from \(show)"
      case let (one?, nil), let (nil, one?): return "Listened to \(one)"
      case (nil, nil): return nil
      }
    case .steps(let steps, let movement):
      guard steps > 0 else { return nil }
      let verb = switch movement {
      case .running: "Ran"
      case .both: "Walked and ran"
      case .walking, nil: "Walked"
      }
      return "\(verb) \(steps.formatted(.number.locale(locale))) steps"
    case .feeling(let feeling):
      let labels = feeling.labels.compactMap(words)
      if !labels.isEmpty { return "Felt " + labels.formatted(.list(type: .and).locale(locale)) }
      return words(feeling.valence).map { "Felt \($0)" }
    case .event(let title, let place, let start, let hosted):
      guard let title = words(title) else { return nil }
      let ahead = start.map { $0 > now } ?? false
      let verb = hosted ? (ahead ? "Hosting" : "Hosted") : (ahead ? "Going to" : "Went to")
      return words(place).map { "\(verb) \(title) at \($0)" } ?? "\(verb) \(title)"
    case .reflection(let prompt): return words(prompt)
    case .photo, .video, .place, .person: return nil
    }
  }

  private static func listened(_ title: String?, by artist: String?) -> String? {
    switch (title, artist) {
    case let (title?, artist?): "Listened to \(title) by \(artist)"
    case let (one?, nil), let (nil, one?): "Listened to \(one)"
    case (nil, nil): nil
    }
  }

  /// "Walked 3.2 mi in 48 min", in the person's units.
  internal static func line(_ workout: Workout, locale: Locale) -> String {
    let verb: String? = switch workout.activity {
    case .walking: "Walked"
    case .running: "Ran"
    case .cycling: "Cycled"
    case .hiking: "Hiked"
    case .swimming: "Swam"
    case .other: nil
    }
    let distance = workout.meters.flatMap { $0 > 0 ? self.distance($0, swimming: workout.activity == .swimming, locale: locale) : nil }
    let time = workout.seconds.flatMap { $0 >= 60 ? duration($0, locale: locale) : nil }
    if let verb {
      switch (distance, time) {
      case let (distance?, time?): return "\(verb) \(distance) in \(time)"
      case let (distance?, nil): return "\(verb) \(distance)"
      case let (nil, time?): return "\(verb) for \(time)"
      case (nil, nil): return verb
      }
    }
    guard let name = words(workout.name) else {
      return time.map { "Worked out for \($0)" } ?? distance.map { "Worked out, \($0)" } ?? "Worked out"
    }
    switch (distance, time) {
    case let (distance?, time?): return "\(name), \(distance) in \(time)"
    case let (distance?, nil): return "\(name), \(distance)"
    case let (nil, time?): return "\(name) for \(time)"
    case (nil, nil): return name
    }
  }

  /// Miles or kilometres as a road sign has them where the person is; a
  /// swim in yards or metres.
  internal static func distance(_ meters: Double, swimming: Bool, locale: Locale) -> String {
    let measured = Measurement(value: meters, unit: UnitLength.meters)
    if swimming {
      let unit: UnitLength = locale.measurementSystem == .us ? .yards : .meters
      return measured.converted(to: unit).formatted(.measurement(width: .abbreviated, usage: .asProvided,
                                                                 numberFormatStyle: .number.precision(.fractionLength(0))).locale(locale))
    }
    return measured.formatted(.measurement(width: .abbreviated, usage: .road,
                                           numberFormatStyle: .number.precision(.fractionLength(0...1))).locale(locale))
  }

  /// "48 min", "1 hr, 5 min".
  internal static func duration(_ seconds: TimeInterval, locale: Locale) -> String {
    Duration.seconds((seconds / 60).rounded() * 60)
      .formatted(Duration.UnitsFormatStyle(allowedUnits: [.hours, .minutes], width: .abbreviated).locale(locale))
  }

  /// The words, trimmed, or nil when there are none.
  internal static func words(_ text: String?) -> String? {
    let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? nil : trimmed
  }
}

private extension MomentDraft {
  mutating func add(_ line: String) {
    if !lines.contains(line) { lines.append(line) }
  }
}
