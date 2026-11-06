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

  /// Whether the owner gave it its name, once or for good.
  public var isNamed: Bool { namedBy == "own" || namedBy == "place" }

  public func answers(to id: String) -> Bool { self.id == id || ids?.contains(id) == true }
}

public struct CheckInList: Codable, Sendable, Equatable {
  public var items: [CheckIn]
  public var next: String?
}

/// A place the account remembers: a name and the spots it holds.
public struct RememberedPlace: Codable, Sendable, Equatable, Identifiable {
  public struct Corner: Codable, Sendable, Equatable {
    public var lat: Double
    public var lon: Double
  }

  public var id: String
  public var name: String
  public var spots: [Corner]
  public var revision: Int
}

public extension APIClient {
  private struct CheckInAnswer: Decodable { var checkIn: CheckIn }
  private struct PlaceAnswer: Decodable { var place: RememberedPlace }
  private struct PlacesAnswer: Decodable { var places: [RememberedPlace] }
  private struct Deleted: Decodable { var deleted: Int }

  /// Sends one stop. Needs `notes:write`, as adding a note does.
  func report(_ report: CheckInReport, idempotencyKey: String) async throws(APIError) -> CheckIn {
    let answer: CheckInAnswer = try await send("POST", "v1/check-ins", body: report, idempotencyKey: idempotencyKey)
    return answer.checkIn
  }

  /// Stays newest first, within the account's days `from` through `to`.
  /// Needs `activity`.
  func checkIns(from: String? = nil, to: String? = nil, before: String? = nil, limit: Int = 100) async throws(APIError) -> CheckInList {
    var query = [URLQueryItem(name: "limit", value: String(limit))]
    if let from { query.append(URLQueryItem(name: "from", value: from)) }
    if let to { query.append(URLQueryItem(name: "to", value: to)) }
    if let before { query.append(URLQueryItem(name: "before", value: before)) }
    return try await send("GET", "v1/check-ins", query: query)
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
