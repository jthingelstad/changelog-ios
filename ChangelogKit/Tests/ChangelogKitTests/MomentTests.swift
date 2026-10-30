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
}
