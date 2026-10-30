#if canImport(JournalingSuggestions)
import ChangelogKit
import CoreLocation
import HealthKit
@preconcurrency import JournalingSuggestions

/// Reads a moment picked in Apple's Journaling Suggestions picker into plain
/// values. What each kind puts in the draft is `Moment`'s, in ChangelogKit,
/// where it is tested; this only copies the framework's fields across. The
/// framework is on a phone only (the simulator's SDK has none), so this is
/// built for a phone alone and checked by hand (`docs/PHONE-TEST.md`).
extension Moment {
  @MainActor
  static func read(_ suggestion: JournalingSuggestion) async -> Moment {
    var pieces: [Piece] = []
    var dates: [Date] = []
    for item in suggestion.items {
      let read = await read(item)
      pieces += read.pieces
      if let date = read.date { dates.append(date) }
    }
    return Moment(date: suggestion.date?.start ?? dates.min(), pieces: pieces)
  }

  /// One item, read as each kind it holds once: a Live Photo as its still
  /// (never also as a photo or a video), a workout before a group of them,
  /// a song before other media. Each kind is asked for by its own type (a
  /// generic helper's conformance could be isolated), one after another.
  @MainActor
  private static func read(_ item: JournalingSuggestion.ItemContent) async -> (pieces: [Piece], date: Date?) {
    var pieces: [Piece] = []
    var date: Date?
    if let live = try? await item.content(forType: JournalingSuggestion.LivePhoto.self) {
      pieces.append(.photo(live.image))
      date = live.date
    } else if let photo = try? await item.content(forType: JournalingSuggestion.Photo.self) {
      pieces.append(.photo(photo.photo))
      date = photo.date
    } else if let video = try? await item.content(forType: JournalingSuggestion.Video.self) {
      pieces.append(.video)
      date = video.date
    }
    if let workout = try? await item.content(forType: JournalingSuggestion.Workout.self) {
      pieces.append(.workout(Self.workout(workout)))
      date = date ?? workout.details?.date?.start
    } else if let group = try? await item.content(forType: JournalingSuggestion.WorkoutGroup.self) {
      pieces += group.workouts.map { .workout(Self.workout($0)) }
      date = date ?? group.workouts.compactMap { $0.details?.date?.start }.min()
    }
    if let location = try? await item.content(forType: JournalingSuggestion.Location.self) {
      pieces.append(place(location))
      date = date ?? location.date
    } else if let group = try? await item.content(forType: JournalingSuggestion.LocationGroup.self),
              let first = group.locations.first(where: { $0.location != nil }) ?? group.locations.first {
      // One place a note: the first with coordinates, named once.
      pieces.append(place(first))
      date = date ?? first.date
    }
    if let song = try? await item.content(forType: JournalingSuggestion.Song.self) {
      pieces.append(.song(title: song.song, artist: song.artist))
      date = date ?? song.date
    } else if let podcast = try? await item.content(forType: JournalingSuggestion.Podcast.self) {
      pieces.append(.podcast(episode: podcast.episode, show: podcast.show))
      date = date ?? podcast.date
    } else if let media = try? await item.content(forType: JournalingSuggestion.GenericMedia.self) {
      pieces.append(.played(title: media.title, artist: media.artist))
      date = date ?? media.date
    }
    if let motion = try? await item.content(forType: JournalingSuggestion.MotionActivity.self) {
      pieces.append(.steps(motion.steps, movement(motion.movementType)))
      date = date ?? motion.date?.start
    }
    if let mind = try? await item.content(forType: JournalingSuggestion.StateOfMind.self) {
      pieces.append(.feeling(Feeling(labels: mind.state.labels.compactMap(word), valence: valence(mind.state.valenceClassification))))
      date = date ?? mind.state.startDate
    }
    if let event = try? await item.content(forType: JournalingSuggestion.EventPoster.self) {
      pieces.append(.event(title: String(event.title.characters), place: event.placeName, start: event.eventStart,
                           hosted: event.isHost == true))
      date = date ?? event.eventStart
    }
    if let contact = try? await item.content(forType: JournalingSuggestion.Contact.self) {
      pieces.append(.person(contact.name))
    }
    if let reflection = try? await item.content(forType: JournalingSuggestion.Reflection.self) {
      pieces.append(.reflection(reflection.prompt))
    }
    return (pieces, date)
  }

  private static func place(_ location: JournalingSuggestion.Location) -> Piece {
    let spot = location.location.flatMap { found -> Spot? in
      guard CLLocationCoordinate2DIsValid(found.coordinate) else { return nil }
      return Spot(lat: found.coordinate.latitude, lon: found.coordinate.longitude,
                  accuracyM: found.horizontalAccuracy >= 0 ? found.horizontalAccuracy.rounded() : nil)
    }
    return .place(spot, name: location.place ?? location.city)
  }

  private static func workout(_ workout: JournalingSuggestion.Workout) -> Workout {
    let details = workout.details
    let activity: Workout.Activity = switch details?.activityType {
    case .walking: .walking
    case .running: .running
    case .cycling: .cycling
    case .hiking: .hiking
    case .swimming: .swimming
    default: .other
    }
    let meters = details?.distance.flatMap { $0.is(compatibleWith: .meter()) ? $0.doubleValue(for: .meter()) : nil }
    return Workout(activity: activity, name: details?.localizedName, meters: meters, seconds: details?.date?.duration)
  }

  private static func movement(_ type: JournalingSuggestion.MotionActivity.MovementType?) -> Movement? {
    guard let type else { return nil }
    if type == .running { return .running }
    if type == .runningWalking { return .both }
    return type == .walking ? .walking : nil
  }

  /// Health's word for a feeling, as its State of Mind shows it.
  private static func word(_ label: HKStateOfMind.Label) -> String? {
    switch label {
    case .amazed: "amazed"
    case .amused: "amused"
    case .angry: "angry"
    case .annoyed: "annoyed"
    case .anxious: "anxious"
    case .ashamed: "ashamed"
    case .brave: "brave"
    case .calm: "calm"
    case .confident: "confident"
    case .content: "content"
    case .disappointed: "disappointed"
    case .discouraged: "discouraged"
    case .disgusted: "disgusted"
    case .drained: "drained"
    case .embarrassed: "embarrassed"
    case .excited: "excited"
    case .frustrated: "frustrated"
    case .grateful: "grateful"
    case .guilty: "guilty"
    case .happy: "happy"
    case .hopeful: "hopeful"
    case .hopeless: "hopeless"
    case .indifferent: "indifferent"
    case .irritated: "irritated"
    case .jealous: "jealous"
    case .joyful: "joyful"
    case .lonely: "lonely"
    case .overwhelmed: "overwhelmed"
    case .passionate: "passionate"
    case .peaceful: "peaceful"
    case .proud: "proud"
    case .relieved: "relieved"
    case .sad: "sad"
    case .satisfied: "satisfied"
    case .scared: "scared"
    case .stressed: "stressed"
    case .surprised: "surprised"
    case .worried: "worried"
    @unknown default: nil
    }
  }

  private static func valence(_ classification: HKStateOfMind.ValenceClassification) -> String? {
    switch classification {
    case .veryUnpleasant: "very unpleasant"
    case .unpleasant: "unpleasant"
    case .slightlyUnpleasant: "slightly unpleasant"
    case .neutral: "neutral"
    case .slightlyPleasant: "slightly pleasant"
    case .pleasant: "pleasant"
    case .veryPleasant: "very pleasant"
    @unknown default: nil
    }
  }
}
#elseif DEBUG
import ChangelogKit
import Foundation

extension Moment {
  /// The UI test cycle's moment, a simulator having no picker
  /// (`CHANGELOG_MOMENT` in a debug build): a walk two days ago by a lake,
  /// a song, and a video it leaves out. Fictional.
  static var standIn: Moment {
    Moment(date: .now.addingTimeInterval(-2 * 86400), pieces: [
      .workout(Workout(activity: .walking, meters: 5150, seconds: 2890)),
      .place(Spot(lat: 44.9221, lon: -93.3110, accuracyM: 35), name: "Lake Harriet"),
      .song(title: "A Song", artist: "A Band"),
      .video,
    ])
  }
}
#endif
