import Foundation
import Testing
@testable import ChangelogKit

@Suite struct MomentTests {
  private let chicago = TimeZone(identifier: "America/Chicago")!
  private let us = Locale(identifier: "en_US")
  /// 2026-10-29 12:00 in Chicago, the dev server's today.
  private let now = Date(timeIntervalSince1970: 1_793_293_200)
  private let today = "2026-10-29"

  private func draft(_ pieces: [Moment.Piece], at date: Date? = nil, room: Int = 20, canAddFiles: Bool = true,
                     locale: Locale? = nil) -> MomentDraft {
    Moment(date: date ?? now, pieces: pieces)
      .draft(today: today, timeZone: chicago, room: room, canAddFiles: canAddFiles, now: now, locale: locale ?? us)
  }

  private func line(_ piece: Moment.Piece, locale: Locale? = nil) -> String? {
    draft([piece], locale: locale).lines.first
  }

  @Test func aWorkoutIsOneLineInThePersonsUnits() {
    let walk = Moment.Workout(activity: .walking, meters: 5150, seconds: 48 * 60 + 10)
    #expect(line(.workout(walk)) == "Walked 3.2 mi in 48 min")
    #expect(line(.workout(walk), locale: Locale(identifier: "de_DE")) == "Walked 5,2 km in 48 Min.")
    #expect(line(.workout(Moment.Workout(activity: .running, meters: 10_000, seconds: 3900))) == "Ran 6.2 mi in 1 hr, 5 min")
    #expect(line(.workout(Moment.Workout(activity: .cycling, meters: 20_000))) == "Cycled 12.4 mi")
    #expect(line(.workout(Moment.Workout(activity: .hiking, seconds: 7200))) == "Hiked for 2 hr")
    // A swim in yards where a pool is, in metres elsewhere.
    #expect(line(.workout(Moment.Workout(activity: .swimming, meters: 1500, seconds: 2400))) == "Swam 1,640 yd in 40 min")
    #expect(line(.workout(Moment.Workout(activity: .swimming, meters: 1500)), locale: Locale(identifier: "en_GB")) == "Swam 1,500 m")
  }

  @Test func aWorkoutWithoutAVerbGoesByItsName() {
    #expect(line(.workout(Moment.Workout(activity: .other, name: "Yoga", seconds: 1800))) == "Yoga for 30 min")
    #expect(line(.workout(Moment.Workout(activity: .other, name: "Rowing", meters: 2000, seconds: 480))) == "Rowing, 1.2 mi in 8 min")
    #expect(line(.workout(Moment.Workout(activity: .other, seconds: 1200))) == "Worked out for 20 min")
    #expect(line(.workout(Moment.Workout(activity: .other))) == "Worked out")
    // Under a minute says no time at all.
    #expect(line(.workout(Moment.Workout(activity: .walking, seconds: 40))) == "Walked")
  }

  @Test func musicAndPodcastsSayWhatPlayed() {
    #expect(line(.song(title: "Clair de Lune", artist: "Claude Debussy")) == "Listened to Clair de Lune by Claude Debussy")
    #expect(line(.song(title: " Clair de Lune ", artist: nil)) == "Listened to Clair de Lune")
    #expect(line(.played(title: nil, artist: "A Band")) == "Listened to A Band")
    #expect(line(.podcast(episode: "The Big Squeeze", show: "A Money Show")) == "Listened to The Big Squeeze from A Money Show")
    #expect(line(.podcast(episode: nil, show: "A Money Show")) == "Listened to A Money Show")
    #expect(line(.song(title: " ", artist: nil)) == nil)
  }

  @Test func stepsFeelingsEventsPeopleAndPrompts() {
    #expect(line(.steps(8412, nil)) == "Walked 8,412 steps")
    #expect(line(.steps(8412, .running)) == "Ran 8,412 steps")
    #expect(line(.steps(8412, .both)) == "Walked and ran 8,412 steps")
    #expect(line(.steps(0, nil)) == nil)
    #expect(line(.feeling(Moment.Feeling(labels: ["calm"]))) == "Felt calm")
    #expect(line(.feeling(Moment.Feeling(labels: ["calm", "grateful", "happy"]))) == "Felt calm, grateful, and happy")
    #expect(line(.feeling(Moment.Feeling(labels: [], valence: "slightly pleasant"))) == "Felt slightly pleasant")
    let past = now.addingTimeInterval(-86400), ahead = now.addingTimeInterval(86400)
    #expect(line(.event(title: "Game night", place: "The Lake House", start: past, hosted: false)) == "Went to Game night at The Lake House")
    #expect(line(.event(title: "Game night", place: nil, start: past, hosted: true)) == "Hosted Game night")
    #expect(line(.event(title: "Game night", place: nil, start: ahead, hosted: false)) == "Going to Game night")
    #expect(draft([.person("Alex"), .song(title: "A Song", artist: nil), .person("Sam")]).lines
      == ["With Alex and Sam", "Listened to A Song"])
    #expect(line(.reflection("What made you smile today?")) == "What made you smile today?")
  }

  @Test func photosGoOnTheDraftWithinItsRoom() {
    let photos = (1...3).map { Moment.Piece.photo(URL(filePath: "/tmp/moment \($0).heic")) }
    #expect(draft(photos).photos.count == 3)
    #expect(draft(photos).notice == nil)
    let full = draft(photos, room: 1)
    #expect(full.photos == [URL(filePath: "/tmp/moment 1.heic")])
    #expect(full.notice == "A note holds up to 20 files, so 2 of the moment's photos aren't on it.")
    let none = draft(photos + [.song(title: "A Song", artist: nil)], canAddFiles: false)
    #expect(none.photos.isEmpty)
    #expect(none.lines == ["Listened to A Song"])
    #expect(none.notice == "This token can't add files, so the moment's 3 photos aren't on this note.")
  }

  @Test func aVideoIsLeftOutAndTheDraftSaysSo() {
    let made = draft([.video, .photo(URL(filePath: "/tmp/still.jpg"))])
    #expect(made.photos.count == 1)
    #expect(made.lines.isEmpty)
    #expect(made.notice == "Release Notes doesn't keep video, so the moment's video isn't on this note.")
    // A video alone brings nothing, so the draft keeps its day.
    let alone = draft([.video, .video], at: now.addingTimeInterval(-3 * 86400))
    #expect(alone.isEmpty)
    #expect(alone.day == nil)
    #expect(alone.notice == "Release Notes doesn't keep video, so the moment's 2 videos aren't on this note.")
    #expect(draft([.song(title: nil, artist: nil)]).notice == "That moment has nothing Changelog can put on a note.")
  }

  @Test func aPlaceIsASpotForHereOnceAPick() {
    let lake = Spot(lat: 44.9221, lon: -93.3110, accuracyM: 35)
    let made = draft([.place(lake, name: "Lake Harriet"), .place(Spot(lat: 44.98, lon: -93.27), name: "Downtown")])
    #expect(made.spot == lake)
    #expect(made.lines.isEmpty)
    // Without coordinates there is nothing for Here to name: the name is a line.
    #expect(draft([.place(nil, name: "Lake Harriet")]).lines == ["At Lake Harriet"])
    #expect(draft([.place(nil, name: nil)]).isEmpty)
  }

  @Test func aMomentFilesToItsOwnDay() {
    let walk = Moment.Piece.workout(Moment.Workout(activity: .walking, seconds: 1800))
    // Saturday evening in Chicago is still Saturday there, though Sunday in UTC.
    let saturday = Date(timeIntervalSince1970: 1_792_902_600) // 2026-10-24 23:30 in Chicago
    #expect(Moment.day(of: saturday, in: chicago) == "2026-10-24")
    #expect(Moment.day(of: saturday, in: TimeZone(identifier: "UTC")!) == "2026-10-25")
    #expect(draft([walk], at: saturday).day == "2026-10-24")
    // Today, or a day ahead (an event to come), files to today.
    #expect(draft([walk], at: now).day == nil)
    #expect(draft([walk], at: now.addingTimeInterval(2 * 86400)).day == nil)
    // No date at all: today.
    #expect(Moment(date: nil, pieces: [walk]).draft(today: today, timeZone: chicago, room: 20, canAddFiles: true).day == nil)
  }

  // MARK: Values beside the words

  /// Each piece goes as Release Notes keeps it, with the line it wrote;
  /// photos, videos and places aren't pieces, and people are one.
  @Test func eachPieceIsAValueWithItsLine() throws {
    let start = now.addingTimeInterval(-2 * 3600)
    let made = draft([
      .workout(Moment.Workout(activity: .walking, meters: 5150.04, seconds: 2890)),
      .person("Ana"),
      .song(title: "A Song", artist: "A Band"),
      .photo(URL(filePath: "/tmp/moment.heic")), .video,
      .place(Spot(lat: 44.9221, lon: -93.3110), name: "Lake Harriet"),
      .person("Ben"),
      .podcast(episode: nil, show: "A Show"),
      .played(title: "A Tune", artist: nil),
      .steps(8214, .both),
      .feeling(Moment.Feeling(labels: ["calm", "calm", "grateful"], valence: "slightly pleasant")),
      .event(title: "Picnic", place: "The Park", start: start, hosted: true),
      .reflection("What made today good?")
    ], at: start)
    let values = try #require(made.values)
    #expect(values.at == "2026-10-29T10:00:00-05:00")
    #expect(values.pieces.map(\.line) == made.lines)
    #expect(values.pieces.map(\.item) == [
      NoteMoment.Item(kind: "workout", activity: "walking", distanceM: 5150, durationS: 2890),
      NoteMoment.Item(kind: "people", names: ["Ana", "Ben"]),
      NoteMoment.Item(kind: "song", title: "A Song", artist: "A Band"),
      NoteMoment.Item(kind: "podcast", show: "A Show"),
      NoteMoment.Item(kind: "played", title: "A Tune"),
      NoteMoment.Item(kind: "steps", count: 8214, movement: "both"),
      NoteMoment.Item(kind: "feeling", labels: ["calm", "grateful"], valence: "slightly_pleasant"),
      NoteMoment.Item(kind: "event", title: "Picnic", place: "The Park", start: "2026-10-29T10:00:00-05:00", hosted: true),
      NoteMoment.Item(kind: "reflection", prompt: "What made today good?")
    ])
  }

  /// What Release Notes would refuse is left off the value, never sent to
  /// be refused; the line still goes in the words.
  @Test func aValueIsTidiedAndKeptInRange() throws {
    let long = String(repeating: "x", count: 201)
    let made = draft([
      .song(title: "  A   Song ", artist: long),
      .workout(Moment.Workout(activity: .other, name: long, meters: 2_000_000, seconds: 0.04)),
      .podcast(episode: long, show: nil),
      .feeling(Moment.Feeling(labels: (1...12).map { "word\($0)" } + [String(repeating: "y", count: 41)], valence: "glad")),
      .feeling(Moment.Feeling(labels: [], valence: "glad")),
      .reflection(String(repeating: "z", count: 401))
    ] + (1...25).map { .person("Person \($0)") })
    let items = try #require(made.values).pieces.map(\.item)
    #expect(items[0] == NoteMoment.Item(kind: "song", title: "A Song"))
    #expect(items[1] == NoteMoment.Item(kind: "workout", activity: "other"))
    #expect(items[2].labels == (1...10).map { "word\($0)" } && items[2].valence == nil)
    #expect(items[3].kind == "people" && items[3].names?.count == 20)
    #expect(items.count == 4)
    // The lines are as before, each piece's own.
    #expect(made.lines.count == 7)
    // A moment with no piece to send has no values.
    #expect(draft([.photo(URL(filePath: "/tmp/moment.heic")), .place(nil, name: "Lake Harriet")]).values == nil)
  }

  /// At Commit only the pieces whose line is still in the words go: words
  /// added around a line keep it, a line deleted or changed takes its piece.
  @Test func onlyWhatTheWordsStillSayGoes() throws {
    let values = try #require(draft([
      .workout(Moment.Workout(activity: .walking, meters: 5150, seconds: 2890)),
      .song(title: "A Song", artist: "A Band"),
      .person("Ana")
    ]).values)
    let all = "Walked 3.2 mi in 48 min, with a blister\nListened to A Song by A Band\nWith Ana #walks"
    #expect(values.kept(in: all)?.items.map(\.kind) == ["workout", "song", "people"])
    #expect(values.kept(in: all)?.at == values.at)
    #expect(values.kept(in: "Walked 3.2 miles\nWith Ana")?.items.map(\.kind) == ["people"])
    #expect(values.kept(in: "Just words") == nil)
    // A word of a line made longer is a changed line; a line said twice,
    // once whole, is still said.
    #expect(values.kept(in: "With Anabel") == nil)
    #expect(values.kept(in: "Walked 3.2 mi in 48 minutes") == nil)
    #expect(values.kept(in: "(With Ana.) With Anabel")?.items.map(\.kind) == ["people"])
    #expect(values.kept(in: "With Anabel, With Ana")?.items.map(\.kind) == ["people"])
    #expect(values.said(in: all) == values)
    // Up to the twelve Release Notes takes.
    let many = MomentValues(pieces: (1...14).map { (n: Int) in
      MomentValues.Piece(line: "Line \(n)", item: NoteMoment.Item(kind: "steps", count: n))
    })
    let lines = (1...14).map { "Line \($0)" }.joined(separator: "\n")
    let twelve = try #require(many.kept(in: lines))
    #expect(twelve.items.compactMap(\.count) == Array(1...12))
  }

  /// A second moment in the same draft adds its pieces, none twice, and
  /// the moment began at the earlier start.
  @Test func aSecondMomentAddsItsPieces() throws {
    let song = try #require(draft([.song(title: "A Song", artist: nil)], at: now).values)
    let walk = try #require(draft([.workout(Moment.Workout(activity: .walking, seconds: 1800)), .song(title: "A Song", artist: nil)],
                                  at: now.addingTimeInterval(-3600)).values)
    let both = song.adding(walk)
    #expect(both.pieces.map(\.item.kind) == ["song", "workout"])
    #expect(both.at == walk.at)
    #expect(walk.adding(song).at == walk.at)
    #expect(MomentValues(pieces: []).adding(song).at == song.at)
  }

  /// On the wire the fields are snake_case, and what is nil isn't sent.
  @Test func aMomentGoesAsTheAPINamesIt() throws {
    let moment = NoteMoment(at: "2026-10-29T07:40:00-05:00",
                            items: [NoteMoment.Item(kind: "workout", activity: "walking", distanceM: 5150, durationS: 2890)])
    let body = try JSONSerialization.jsonObject(with: APIClient.encoder.encode(NoteRequest(text: "Walked", moment: moment))) as? NSDictionary
    #expect(body == [
      "text": "Walked",
      "moment": ["at": "2026-10-29T07:40:00-05:00",
                 "items": [["kind": "workout", "activity": "walking", "distance_m": 5150, "duration_s": 2890]]]
    ] as NSDictionary)
    // Read back as Release Notes returns it.
    let read = try APIClient.decoder.decode(NoteDetail.self, from: Data(#"""
      {"id":"t-1","date":"2026-10-29","text":"Walked","revision":"r","moment":{"at":"2026-10-29T07:40:00-05:00",
       "items":[{"kind":"workout","activity":"walking","distance_m":5150,"duration_s":2890}]}}
      """#.utf8))
    #expect(read.moment == moment)
  }
}
