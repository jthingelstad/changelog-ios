import Foundation

/// A stop as the phone reports it (`POST /v1/check-ins`): what iOS said of a
/// visit, or the moment Check in now was tapped. It waits in the Outbox under
/// its own key. The app keeps no server ids: a later report of the same stay,
/// with the same source and arrival to the second, fills it in.
public struct CheckInReport: Codable, Sendable, Equatable {
  public var arrived: String?
  public var left: String?
  public var lat: Double
  public var lon: Double
  public var accuracyM: Double?
  public var timeZone: String?
  /// `visit` for a stop iOS noticed, `tap` for one the owner asked for.
  public var source: String

  public init(arrived: String?, left: String?, lat: Double, lon: Double, accuracyM: Double?, timeZone: String?, source: String) {
    self.arrived = arrived
    self.left = left
    self.lat = lat
    self.lon = lon
    self.accuracyM = accuracyM
    self.timeZone = timeZone
    self.source = source
  }

  /// A visit as iOS delivered it, which writes an unknown arrival as the
  /// distant past and "still there" as the distant future. Nil when it knows
  /// neither time, which Release Notes would refuse.
  public static func visit(arrival: Date, departure: Date, lat: Double, lon: Double, accuracy: Double,
                           timeZone: TimeZone = .current) -> CheckInReport? {
    let arrived = arrival <= .distantPast ? nil : Timestamp.string(arrival, timeZone: timeZone)
    let left = departure >= .distantFuture ? nil : Timestamp.string(departure, timeZone: timeZone)
    guard arrived != nil || left != nil else { return nil }
    return CheckInReport(arrived: arrived, left: left, lat: lat, lon: lon, accuracyM: accuracy >= 0 ? accuracy : nil,
                         timeZone: timeZone.identifier, source: "visit")
  }

  /// Check in now: the moment it was tapped, so one that waited in the queue
  /// keeps its time. A tap is never continued, so it has no `left`.
  public static func tap(at moment: Date, spot: Spot, timeZone: TimeZone = .current) -> CheckInReport {
    CheckInReport(arrived: Timestamp.string(moment, timeZone: timeZone), left: nil, lat: spot.lat, lon: spot.lon,
                  accuracyM: spot.accuracyM, timeZone: timeZone.identifier, source: "tap")
  }
}

/// One stay as `/v1` reads it: every stop read as one, under any of its ids.
public struct CheckIn: Codable, Sendable, Equatable, Hashable, Identifiable {
  public var id: String
  public var ids: [String]?
  public var at: String
  public var day: String
  public var arrived: String?
  public var left: String?
  public var lat: Double
  public var lon: Double
  public var accuracyM: Double?
  public var timeZone: String?
  public var source: String
  public var revision: Int
  public var label: String
  /// What the label came from: `own`, `place`, `district` or `none`.
  public var namedBy: String
  /// The remembered place's id, when that is what named it.
  public var place: String?
  /// A name of its own, given once.
  public var name: String?
  public var token: String?
  public var client: String?
  /// The keys of the tags of every check-in in it, and their names (API
  /// 1.21.0); nil or empty for none.
  public var tags: [String]? = nil
  public var tagNames: [String]? = nil

  /// Its tags by name.
  public var tagList: [Tag] { Hashtags.named(tags, tagNames) }

  /// Whether the owner gave it its name, once or for good.
  public var isNamed: Bool { namedBy == "own" || namedBy == "place" }

  public func answers(to id: String) -> Bool { self.id == id || ids?.contains(id) == true }
}

public struct CheckInList: Codable, Sendable, Equatable {
  public var items: [CheckIn]
  public var next: String?
}

/// What reporting a stop answers (`POST /v1/check-ins`): the stay, and whether
/// it was kept (API 1.20.0). A stop at a place the owner ignores isn't: nothing
/// was stored, and `checkIn` only shows what it would have been, with an id that
/// names nothing, so it is never kept or opened. A server before 1.20.0 keeps
/// every one and doesn't say.
public struct CheckInReceipt: Decodable, Sendable, Equatable {
  public var checkIn: CheckIn
  public var kept: Bool

  public init(checkIn: CheckIn, kept: Bool = true) {
    self.checkIn = checkIn
    self.kept = kept
  }

  private enum CodingKeys: String, CodingKey { case checkIn, kept }

  public init(from decoder: Decoder) throws {
    let keys = try decoder.container(keyedBy: CodingKeys.self)
    checkIn = try keys.decode(CheckIn.self, forKey: .checkIn)
    kept = try keys.decodeIfPresent(Bool.self, forKey: .kept) ?? true
  }

  /// The ignored place's name, when the token was told it (one that can't read
  /// the log or every note isn't); nil for a stop that was kept.
  public var ignoredAt: String? {
    guard !kept, checkIn.namedBy == "place", !checkIn.label.isEmpty else { return nil }
    return checkIn.label
  }
}

/// A place the account remembers: a name and the spots it holds. Ignored
/// (API 1.20.0, "Ignore this location"), no new stop there is kept, and the
/// stays already there are hidden, not deleted, until it is unignored.
public struct RememberedPlace: Codable, Sendable, Equatable, Identifiable {
  public struct Corner: Codable, Sendable, Equatable {
    public var lat: Double
    public var lon: Double
  }

  public var id: String
  public var name: String
  public var spots: [Corner]
  public var revision: Int
  /// A server before 1.20.0 leaves it out: never ignored.
  public var ignored: Bool
  /// How many stays are there, hidden ones too. A read of the one place
  /// (`GET /v1/check-ins/places/{id}`) says, and a change that gave it a tag
  /// (API 1.21.0), to offer tagging them.
  public var checkIns: Int?
  /// The tags every new stop here gets (API 1.21.0).
  public var tags: [Tag]

  public init(id: String, name: String, spots: [Corner], revision: Int, ignored: Bool = false, checkIns: Int? = nil,
              tags: [Tag] = []) {
    self.id = id
    self.name = name
    self.spots = spots
    self.revision = revision
    self.ignored = ignored
    self.checkIns = checkIns
    self.tags = tags
  }

  private enum CodingKeys: String, CodingKey { case id, name, spots, revision, ignored, checkIns, tags, tagNames }

  public func encode(to encoder: Encoder) throws {
    var keys = encoder.container(keyedBy: CodingKeys.self)
    try keys.encode(id, forKey: .id)
    try keys.encode(name, forKey: .name)
    try keys.encode(spots, forKey: .spots)
    try keys.encode(revision, forKey: .revision)
    try keys.encode(ignored, forKey: .ignored)
    try keys.encodeIfPresent(checkIns, forKey: .checkIns)
    if !tags.isEmpty {
      try keys.encode(tags.map(\.key), forKey: .tags)
      try keys.encode(tags.map(\.name), forKey: .tagNames)
    }
  }

  public init(from decoder: Decoder) throws {
    let keys = try decoder.container(keyedBy: CodingKeys.self)
    id = try keys.decode(String.self, forKey: .id)
    name = try keys.decode(String.self, forKey: .name)
    spots = try keys.decode([Corner].self, forKey: .spots)
    revision = try keys.decode(Int.self, forKey: .revision)
    ignored = try keys.decodeIfPresent(Bool.self, forKey: .ignored) ?? false
    checkIns = try keys.decodeIfPresent(Int.self, forKey: .checkIns)
    tags = Hashtags.named(try keys.decodeIfPresent([String].self, forKey: .tags),
                          try keys.decodeIfPresent([String].self, forKey: .tagNames))
  }
}

public extension APIClient {
  private struct CheckInAnswer: Decodable { var checkIn: CheckIn }
  private struct PlaceAnswer: Decodable { var place: RememberedPlace }
  private struct PlacesAnswer: Decodable { var places: [RememberedPlace] }
  private struct Deleted: Decodable { var deleted: Int }
  private struct Tagged: Decodable { var tagged: Int }

  /// Sends one stop. Needs `notes:write`, as adding a note does. A stop at an
  /// ignored place answers 200 with `kept` false: done, and nothing stored.
  func report(_ report: CheckInReport, idempotencyKey: String) async throws(APIError) -> CheckInReceipt {
    try await send("POST", "v1/check-ins", body: report, idempotencyKey: idempotencyKey)
  }

  /// Stays newest first, within the account's days `from` through `to`, or
  /// only those with a tag, by any spelling (API 1.21.0). Needs `activity`.
  func checkIns(from: String? = nil, to: String? = nil, before: String? = nil, tag: String? = nil,
                limit: Int = 100) async throws(APIError) -> CheckInList {
    var query = [URLQueryItem(name: "limit", value: String(limit))]
    if let from { query.append(URLQueryItem(name: "from", value: from)) }
    if let to { query.append(URLQueryItem(name: "to", value: to)) }
    if let before { query.append(URLQueryItem(name: "before", value: before)) }
    if let tag { query.append(URLQueryItem(name: "tag", value: tag)) }
    return try await send("GET", "v1/check-ins", query: query)
  }

  /// A stay's whole list of tags, by name, set on every check-in in it; its
  /// name stays as it is (API 1.21.0).
  func tagCheckIn(id: String, tags: [Tag], revision: Int, idempotencyKey: String) async throws(APIError) -> CheckIn {
    struct Body: Encodable { var tags: [String]; var revision: Int }
    let answer: CheckInAnswer = try await send("PATCH", "v1/check-ins/\(id)", body: Body(tags: tags.map(\.name), revision: revision),
                                               idempotencyKey: idempotencyKey)
    return answer.checkIn
  }

  /// A name on this stay alone, or nil to take its own name off.
  func nameCheckIn(id: String, name: String?, revision: Int, idempotencyKey: String) async throws(APIError) -> CheckIn {
    let answer: CheckInAnswer = try await send("PATCH", "v1/check-ins/\(id)", body: CheckInNaming(name: name, revision: revision),
                                               idempotencyKey: idempotencyKey)
    return answer.checkIn
  }

  /// Deletes the whole stay.
  func deleteCheckIn(id: String, idempotencyKey: String) async throws(APIError) {
    let _: Empty = try await send("DELETE", "v1/check-ins/\(id)", idempotencyKey: idempotencyKey, expect: 204)
  }

  /// Deletes every check-in and answers how many went. The remembered places
  /// stay. Needs `notes:all`.
  func deleteAllCheckIns(idempotencyKey: String) async throws(APIError) -> Int {
    let answer: Deleted = try await send("DELETE", "v1/check-ins", query: [URLQueryItem(name: "confirm", value: "all")],
                                         idempotencyKey: idempotencyKey)
    return answer.deleted
  }

  /// Needs `activity`.
  func rememberedPlaces() async throws(APIError) -> [RememberedPlace] {
    let answer: PlacesAnswer = try await send("GET", "v1/check-ins/places")
    return answer.places
  }

  /// Remembers a place, or adds this spot to a name already used. Needs
  /// `notes:all`.
  func remember(name: String, lat: Double, lon: Double, idempotencyKey: String) async throws(APIError) -> RememberedPlace {
    struct Body: Encodable { var name: String; var lat: Double; var lon: Double }
    let answer: PlaceAnswer = try await send("POST", "v1/check-ins/places", body: Body(name: name, lat: lat, lon: lon),
                                             idempotencyKey: idempotencyKey)
    return answer.place
  }

  func renamePlace(id: String, name: String, idempotencyKey: String) async throws(APIError) -> RememberedPlace {
    struct Body: Encodable { var name: String }
    let answer: PlaceAnswer = try await send("PATCH", "v1/check-ins/places/\(id)", body: Body(name: name), idempotencyKey: idempotencyKey)
    return answer.place
  }

  func forgetPlace(id: String, idempotencyKey: String) async throws(APIError) {
    let _: Empty = try await send("DELETE", "v1/check-ins/places/\(id)", idempotencyKey: idempotencyKey, expect: 204)
  }

  /// One place, with `checkIns`: how many stays are there, hidden ones too, which
  /// Delete existing check-ins here asks with. Needs `activity` (API 1.20.0).
  func rememberedPlace(id: String) async throws(APIError) -> RememberedPlace {
    let answer: PlaceAnswer = try await send("GET", "v1/check-ins/places/\(id)")
    return answer.place
  }

  /// Ignore this location, or stop: ignored, no new stop there is kept, and the
  /// ones already there are hidden until it is unignored. Nothing is deleted.
  /// Needs `notes:all` (API 1.20.0).
  func setPlaceIgnored(id: String, ignored: Bool, idempotencyKey: String) async throws(APIError) -> RememberedPlace {
    struct Body: Encodable { var ignored: Bool }
    let answer: PlaceAnswer = try await send("PATCH", "v1/check-ins/places/\(id)", body: Body(ignored: ignored),
                                             idempotencyKey: idempotencyKey)
    return answer.place
  }

  /// A place's whole list of tags, by name, for the stops to come: the ones
  /// already there keep theirs. When it gained a tag, the answer's `checkIns`
  /// counts them, to offer tagging them too (Jamie's call 6). Needs
  /// `notes:all` (API 1.21.0).
  func setPlaceTags(id: String, tags: [Tag], idempotencyKey: String) async throws(APIError) -> RememberedPlace {
    struct Body: Encodable { var tags: [String] }
    let answer: PlaceAnswer = try await send("PATCH", "v1/check-ins/places/\(id)", body: Body(tags: tags.map(\.name)),
                                             idempotencyKey: idempotencyKey)
    return answer.place
  }

  /// Tags the stays already at a place, hidden ones too, for the count the
  /// owner was shown, and answers how many it tagged. A different count now is
  /// refused, `revision_mismatch` with that count in `APIError.count`: ask
  /// again with the new number. Needs `notes:all` (API 1.21.0).
  func tagCheckIns(atPlace id: String, tags: [Tag], count: Int, idempotencyKey: String) async throws(APIError) -> Int {
    struct Body: Encodable { var tags: [String]; var count: Int }
    let answer: Tagged = try await send("PATCH", "v1/check-ins/places/\(id)/check-ins",
                                        body: Body(tags: tags.map(\.name), count: count), idempotencyKey: idempotencyKey)
    return answer.tagged
  }

  /// Delete existing check-ins here: every stay at the place, hidden ones too,
  /// for the count the owner was shown, and answers how many went. A different
  /// count now is refused, `revision_mismatch` with that count in
  /// `APIError.count`, and nothing goes: show the new number and ask again. The
  /// place stays, ignored or not. Needs `notes:all` (API 1.20.0).
  func deleteCheckIns(atPlace id: String, count: Int, idempotencyKey: String) async throws(APIError) -> Int {
    let answer: Deleted = try await send("DELETE", "v1/check-ins/places/\(id)/check-ins",
                                         query: [URLQueryItem(name: "count", value: String(count))],
                                         idempotencyKey: idempotencyKey)
    return answer.deleted
  }
}

/// `name` is always sent: null is how a stay's own name comes off.
struct CheckInNaming: Encodable {
  var name: String?
  var revision: Int

  private enum CodingKeys: String, CodingKey { case name, revision }

  func encode(to encoder: Encoder) throws {
    var keys = encoder.container(keyedBy: CodingKeys.self)
    try keys.encode(name, forKey: .name)
    try keys.encode(revision, forKey: .revision)
  }
}

/// How a check-in reads, as the web has it (`web/src/lib/check-ins.ts`): by
/// the times of the place it was, in that place's zone. Keep them in step.
public enum CheckInWords {
  public static let unnamed = "Unnamed stop"

  /// "Home", or a stop with no name as a sentence has it.
  public static func stopName(_ label: String?) -> String {
    guard let label, !label.isEmpty, label != unnamed else { return "an unnamed stop" }
    return label
  }

  /// What a tap says at a place the owner ignores, instead of a check-in:
  /// nothing was kept, and why. The place by name when the token was told it.
  public static func notKept(at place: String?) -> String {
    "Not checked in. You ignore \(place ?? "this place"), so no check-ins are kept there."
  }

  /// "70 min", and past two hours "3 hr 5 min".
  public static func lasted(_ minutes: Int) -> String {
    guard minutes >= 120 else { return "\(minutes) min" }
    let (hours, rest) = (minutes / 60, minutes % 60)
    return rest == 0 ? "\(hours) hr" : "\(hours) hr \(rest) min"
  }

  /// What is known of a stay: "9:05 AM to 10:15 AM, 70 min", the day too when
  /// it ends on another. iOS can report a stop with no arrival, and a stop can
  /// still be going on. A tap is a moment, not a stay. Nil with no time at all.
  public static func stay(arrived: String?, left: String?, source: String?, timeZone: TimeZone,
                          locale: Locale = .current) -> String? {
    let from = arrived.flatMap(date), to = left.flatMap(date)
    func time(_ date: Date) -> String {
      date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, timeZone: timeZone))
    }
    func day(_ date: Date) -> String {
      date.formatted(Date.FormatStyle(locale: locale, timeZone: timeZone).month(.abbreviated).day())
    }
    if let from, let to {
      let minutes = Int((to.timeIntervalSince(from) / 60).rounded())
      let end = (day(from) != day(to) ? day(to) + ", " : "") + time(to)
      return "\(time(from)) to \(end), \(lasted(minutes))"
    }
    if let from { return source == "tap" ? "At \(time(from))" : "Since \(time(from))" }
    return to.map { "Until \(time($0))" }
  }

  /// A time as `/v1` writes it, with or without fractions of a second.
  public static func date(_ text: String) -> Date? {
    (try? Date(text, strategy: .iso8601))
      ?? (try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
  }
}
