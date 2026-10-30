import Foundation
import Testing
@testable import ChangelogKit

@Suite struct DraftTests {
  /// The app's own folders, with the space "Application Support" has.
  private func place() -> (store: DraftStore, outbox: Outbox, root: URL) {
    let root = FileManager.default.temporaryDirectory.appending(path: "changelog draft " + UUID().uuidString, directoryHint: .isDirectory)
    let support = root.appending(path: "Application Support", directoryHint: .isDirectory)
    return (DraftStore(file: support.appending(path: "draft.json")), Outbox(file: support.appending(path: "outbox.json")), root)
  }

  private func exists(_ file: QueuedFile, in outbox: Outbox) -> Bool {
    outbox.url(for: file).map { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) } ?? false
  }

  /// iOS ended the app while the person was in the Camera: the words, the
  /// photo and the place are all there on the next launch.
  @Test func aDraftOutlivesTheApp() async throws {
    let (store, outbox, root) = place()
    defer { try? FileManager.default.removeItem(at: root) }
    let photo = QueuedFile(type: "image/jpeg", name: "Photo 1.jpg", size: 4)
    try outbox.keep(Data("jpeg".utf8), as: photo)
    let spot = Spot(lat: 44.948, lon: -93.086, accuracyM: 20)
    let named = DevicePlace(name: "Saint Paul", region: "Minnesota", country: "United States", tz: "America/Chicago",
                            district: "Lowertown", lat: 44.948, lon: -93.086, accuracyM: 20, from: "device")
    let draft = Draft(text: "Planted the garlic, four rows #garden", files: [photo], spot: spot,
                      here: Here(place: named, nearby: [Nearby(name: "Corner Coffee", lat: 44.9481, lon: -93.0861, distanceM: 12)]),
                      venue: "Corner Coffee", spotAt: Date(timeIntervalSince1970: 1_793_257_120))
    #expect(store.save(draft))
    #expect(await store.load(filesIn: outbox) == draft)
    // Read again by the next launch's own store and queue.
    #expect(await DraftStore(file: store.file).load(filesIn: Outbox(file: root.appending(path: "Application Support/outbox.json"))) == draft)
  }

  /// A moment's day and place come back with the draft, and a draft kept
  /// by the build before moments still reads.
  @Test func aMomentsDayAndPlaceOutliveTheApp() async throws {
    let (store, outbox, root) = place()
    defer { try? FileManager.default.removeItem(at: root) }
    let draft = Draft(text: "Walked 3.2 mi in 48 min", spot: Spot(lat: 44.9221, lon: -93.3110, accuracyM: 35),
                      spotAt: Date(timeIntervalSince1970: 1_793_257_120), placeFromMoment: true, day: "2026-10-24")
    #expect(store.save(draft))
    #expect(await store.load(filesIn: outbox) == draft)
    let older = Data(#"{"text":"From before","files":[],"placeOff":false}"#.utf8)
    let read = try JSONDecoder().decode(Draft.self, from: older)
    #expect(read == Draft(text: "From before"))
  }

  @Test func anEmptiedDraftLeavesNothingKept() async throws {
    let (store, outbox, root) = place()
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(store.save(Draft(text: "Half a thought")))
    #expect(store.save(Draft(text: " \n")))
    #expect(await store.load(filesIn: outbox) == nil)
    let file = try #require(store.file)
    #expect(!FileManager.default.fileExists(atPath: file.path(percentEncoded: false)))
    // A place alone is still a draft: the owner asked for Here first.
    #expect(store.save(Draft(spot: Spot(lat: 44.948, lon: -93.086))))
    #expect(await store.load(filesIn: outbox)?.spot == Spot(lat: 44.948, lon: -93.086))
  }

  @Test func aFileWhoseBytesAreGoneIsLeftOff() async throws {
    let (store, outbox, root) = place()
    defer { try? FileManager.default.removeItem(at: root) }
    let kept = QueuedFile(type: "image/png", name: "Photo 1.png", size: 3)
    let gone = QueuedFile(type: "audio/mp4", name: "Voice memo.m4a", size: 3)
    try outbox.keep(Data("png".utf8), as: kept)
    #expect(store.save(Draft(text: "The shelf, level at last", files: [kept, gone])))
    #expect(await store.load(filesIn: outbox)?.files == [kept])
  }

  /// The launch reads the draft back before the queue's sweep, which then
  /// keeps the draft's files and removes only what nothing holds.
  @Test func theSweepAtLaunchKeepsTheDraftsFiles() async throws {
    let (store, outbox, root) = place()
    defer { try? FileManager.default.removeItem(at: root) }
    let photo = QueuedFile(type: "image/jpeg", name: "Photo 1.jpg", size: 4)
    let stray = QueuedFile(type: "image/jpeg", name: "Photo 2.jpg", size: 4)
    try outbox.keep(Data("jpeg".utf8), as: photo)
    try outbox.keep(Data("jpeg".utf8), as: stray)
    #expect(store.save(Draft(text: "", files: [photo])))
    let restored = try #require(await store.load(filesIn: outbox))
    await outbox.sweep(keeping: Set(restored.files.map(\.id)))
    #expect(exists(photo, in: outbox))
    #expect(!exists(stray, in: outbox))
  }

  /// The app ended just after Commit put the note in the queue, before the
  /// draft kept was cleared: the note goes from the queue, and the box is
  /// empty, so the words aren't committed a second time.
  @Test func aDraftThatReachedTheQueueIsNotBroughtBack() async throws {
    let (store, outbox, root) = place()
    defer { try? FileManager.default.removeItem(at: root) }
    let photo = QueuedFile(type: "image/jpeg", name: "Photo 1.jpg", size: 4)
    try outbox.keep(Data("jpeg".utf8), as: photo)
    let stamp = "2026-10-29T19:02:00-05:00"
    let handover = Draft.Handover(text: "The new porch light #house", writtenAt: stamp)
    #expect(store.save(Draft(text: "The new porch light", files: [photo], handover: handover)))
    try await outbox.enqueue(.post(NotePost(text: "The new porch light #house", writtenAt: stamp, files: [photo])))
    #expect(await store.load(filesIn: outbox) == nil)
    let file = try #require(store.file)
    #expect(!FileManager.default.fileExists(atPath: file.path(percentEncoded: false)))
    // Words alone, too.
    let words = Draft.Handover(text: "Fed the starter", writtenAt: stamp)
    #expect(store.save(Draft(text: "Fed the starter", handover: words)))
    try await outbox.enqueue(.note(text: "Fed the starter", date: nil, writtenAt: stamp))
    #expect(await store.load(filesIn: outbox) == nil)
  }

  /// The app ended before the note reached the queue: the words come back.
  @Test func aDraftWhoseCommitNeverReachedTheQueueComesBack() async throws {
    let (store, outbox, root) = place()
    defer { try? FileManager.default.removeItem(at: root) }
    let handover = Draft.Handover(text: "Fed the starter", writtenAt: "2026-10-29T19:02:00-05:00")
    #expect(store.save(Draft(text: "Fed the starter", handover: handover)))
    // Another note in the queue, the same words a minute before, isn't it.
    try await outbox.enqueue(.note(text: "Fed the starter", date: nil, writtenAt: "2026-10-29T19:01:00-05:00"))
    #expect(await store.load(filesIn: outbox) == Draft(text: "Fed the starter"))
  }
}
