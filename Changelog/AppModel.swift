import ChangelogKit
import CoreGraphics
import Foundation
import Observation
import UIKit

/// The app's one source of truth: who it's signed in as, today's version, the
/// tag row, what's waiting to go and what happened today. Everything a note
/// says stays on this phone or goes to Release Notes; nothing is logged.
@MainActor @Observable
final class AppModel {
  enum Phase: Equatable { case starting, signedOut, signedIn }

  private(set) var phase: Phase = .starting
  private(set) var me: Me?
  private(set) var tags: Tags?
  private(set) var today: [ActivityItem] = []
  private(set) var waiting: [OutboxItem] = []
  private(set) var lastFiled: NoteReceipt?
  private(set) var toast: String?
  private(set) var problem: String?
  /// Upcoming reminders as notifications on this phone, off until turned on.
  private(set) var remindersOn: Bool
  private(set) var remindersProblem: String?
  /// Moves on when reminders are turned on or off or the session ends, so
  /// an update still waiting on the server can't schedule them again.
  private var remindersGeneration = 0
  var draft = ""
  /// Files on the draft, their bytes already beside the queue.
  private(set) var draftFiles: [QueuedFile] = []
  /// Small pictures of the draft's photos, for the composer only.
  private(set) var thumbnails: [UUID: CGImage] = [:]

  /// Where the draft was written: the phone's spot, and the place Release
  /// Notes named for it (nil offline, named when the note is sent).
  private(set) var spot: Spot?
  private(set) var here: Here?
  /// A business nearby the owner picked, if any.
  private(set) var venue: String?
  private(set) var locating = false
  private var spotAt: Date?
  /// The owner left the place off this draft.
  private var placeOff = false

  /// "Add where I am": every note gets a place without asking. Kept on
  /// this phone; each Here is a lookup Release Notes pays for.
  var hereByDefault: Bool {
    didSet { defaults.set(hereByDefault, forKey: "here") }
  }

  /// A tag that rides on every note until turned off (a trip, a project).
  /// Kept on this phone only: a habit of the moment, not a setting.
  var sticky: String? {
    didSet { defaults.set(sticky, forKey: "sticky") }
  }

  var server: URL {
    didSet { defaults.set(server.absoluteString, forKey: "server") }
  }

  private let tokens: TokenStore
  private let outbox: Outbox
  private let defaults: UserDefaults
  private var token: String?

  init(tokens: TokenStore = KeychainTokenStore(), defaults: UserDefaults = .standard, outboxFile: URL? = AppModel.outboxFile) {
    self.tokens = tokens
    self.defaults = defaults
    self.outbox = Outbox(file: outboxFile)
    self.sticky = defaults.string(forKey: "sticky")
    self.remindersOn = defaults.bool(forKey: "reminders")
    self.hereByDefault = defaults.bool(forKey: "here")
    self.server = defaults.string(forKey: "server").flatMap(URL.init(string:)) ?? APIClient.production
  }

  static var outboxFile: URL? {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
      .appending(path: "outbox.json")
  }

  static var userAgent: String {
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    return "Changelog/\(version) (iOS \(UIDevice.current.systemVersion))"
  }

  private var client: APIClient? {
    token.map { APIClient(baseURL: server, token: $0, userAgent: Self.userAgent) }
  }

  var version: String? { me?.version }
  var tagRow: [String] { TagRow.tags(tags) }

  // MARK: Signing in and out

  func start() async {
    token = tokens.read()
    waiting = await outbox.waiting
    // A draft's files left by a run that ended; the queue's own stay.
    await outbox.sweep(keeping: Set(draftFiles.map(\.id)))
    #if DEBUG
    // `simctl launch` with SIMCTL_CHILD_CHANGELOG_DEV_TOKEN signs a debug
    // build in to the dev server's fictional account (AGENTS.md, Building).
    // CHANGELOG_DEV_URL picks another port, on this Mac only.
    let environment = ProcessInfo.processInfo.environment
    if token == nil, let dev = environment["CHANGELOG_DEV_TOKEN"] {
      let other = environment["CHANGELOG_DEV_URL"].flatMap(URL.init(string:))
      server = other.flatMap { ["localhost", "127.0.0.1"].contains($0.host() ?? "") ? $0 : nil } ?? APIClient.devServer
      if await signIn(with: dev) == nil { return }
    }
    #endif
    phase = token == nil ? .signedOut : .signedIn
    if phase == .signedIn { await refresh() }
  }

  /// Checks a pasted token with `/v1/me` before keeping it.
  func signIn(with raw: String) async -> String? {
    guard let candidate = TokenFormat.extract(raw) else {
      return "That isn't a Release Notes token. It starts with rn_."
    }
    let probe = APIClient(baseURL: server, token: candidate, userAgent: Self.userAgent)
    do {
      let me = try await probe.me()
      guard me.token.scopes.contains("notes:write") else {
        return "This token can't add notes. Make one with “Add notes” ticked."
      }
      try tokens.write(candidate)
      token = candidate
      self.me = me
      phase = .signedIn
      await refresh()
      return nil
    } catch let error as APIError {
      return error.message
    } catch {
      return "The token couldn't be kept on this phone."
    }
  }

  /// Revokes the token on the server, then forgets it. Notes still waiting
  /// stay on the phone for the next sign-in.
  func signOut() async {
    if let client { try? await client.revokeToken() }
    forget()
  }

  private func forget() {
    tokens.clear()
    token = nil
    me = nil
    tags = nil
    today = []
    phase = .signedOut
    // The next sign-in asks again before any reminder comes.
    remindersOn = false
    remindersGeneration += 1
    defaults.set(false, forKey: "reminders")
    Task { await stopReminders() }
  }

  // MARK: Reading

  func refresh() async {
    guard let client else { return }
    do {
      async let me = client.me()
      async let tags = client.tags()
      self.me = try await me
      self.tags = try? await tags
      problem = nil
      await loadToday()
      await send()
      await updateReminders()
    } catch let error as APIError {
      handle(error)
    } catch {}
  }

  private func loadToday() async {
    guard let client, let me, me.token.scopes.contains("activity") else { return }
    if let page = try? await client.activity(limit: 100) {
      today = page.items.filter { $0.day == me.today || ($0.day == nil && $0.at.hasPrefix(me.today)) }
    }
  }

  // MARK: Reminders

  var canRemind: Bool { me?.token.scopes.contains("upcoming") == true }

  /// The Settings toggle. Turning it on asks iOS first; if notifications are
  /// off for Changelog it stays off and says where to allow them.
  func setReminders(_ on: Bool) async {
    remindersGeneration += 1
    remindersProblem = nil
    if on, !(await PhoneReminders.ask()) {
      remindersProblem = Self.notificationsOff
      return
    }
    remindersOn = on
    defaults.set(on, forKey: "reminders")
    await updateReminders()
  }

  static let notificationsOff = "Notifications are off for Changelog. Allow them in the Settings app, then turn this on again."

  /// Replaces this phone's reminders from a fresh read. Offline, what was
  /// scheduled stays; a token that can't read Upcoming clears it.
  func updateReminders() async {
    let generation = remindersGeneration
    guard remindersOn, token != nil else { return await stopReminders() }
    // A background launch that couldn't reach /v1/me doesn't know the
    // token's scopes yet, which is not the same as lacking one: keep what
    // is scheduled and try again later.
    guard let me else { return PhoneReminders.askForRefresh() }
    guard me.token.scopes.contains("upcoming"), let client else { return await stopReminders() }
    remindersProblem = await PhoneReminders.allowed() ? nil : Self.notificationsOff
    do {
      let answer = try await client.reminders()
      guard wantsReminders(generation) else { return }
      await PhoneReminders.schedule(ReminderPlan.plan(answer, now: .now)) { self.wantsReminders(generation) }
    } catch {
      if error.signedOut || error.code == "scope_required" { return await stopReminders() }
    }
    if wantsReminders(generation) { PhoneReminders.askForRefresh() }
  }

  /// Whether an update begun at `generation` still speaks for the toggle.
  private func wantsReminders(_ generation: Int) -> Bool {
    generation == remindersGeneration && remindersOn && token != nil
  }

  private func stopReminders() async {
    PhoneReminders.cancelRefresh()
    await PhoneReminders.clear()
  }

  /// iOS's background refresh, which may start the app without a window:
  /// read who this is, send what waits, and read the reminders again.
  func backgroundRefresh() async {
    if token == nil { token = tokens.read() }
    guard let client else { return }
    do { me = try await client.me() } catch {
      // A revoked or expired token signs out here as it would on screen.
      if error.signedOut { return handle(error) }
    }
    await send()
    await updateReminders()
  }

  // MARK: Writing

  var canCommit: Bool {
    !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !draftFiles.isEmpty
  }

  /// Queues the draft with the moment it was typed, then tries to send. If
  /// the phone can't keep the queue, the words, files and place go back.
  func commit() async {
    let typed = draft
    var text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
    let files = draftFiles
    guard !text.isEmpty || !files.isEmpty else { return }
    if let sticky { text = Hashtags.adding(sticky, to: text) }
    let placed = (spot: placeOff ? nil : spot, here: here, venue: venue, spotAt: spotAt)
    var place = placed.here?.place
    place?.venue = placed.venue
    draft = ""
    draftFiles = []
    // With "Add where I am" on, the next note within ten minutes takes the
    // same place; a Here asked for once goes with this note alone.
    if hereByDefault { placeOff = false } else { clearPlace(off: false) }
    do {
      if files.isEmpty && placed.spot == nil {
        try await outbox.enqueue(text: text)
      } else {
        try await outbox.enqueue(.post(NotePost(text: text, writtenAt: Timestamp.string(.now), files: files,
                                                spot: placed.spot, place: placed.spot == nil ? nil : place)))
      }
    } catch {
      draft = draft.isEmpty ? typed : typed + "\n" + draft
      draftFiles = files + draftFiles
      if spot == nil, let kept = placed.spot {
        spot = kept
        here = placed.here
        venue = placed.venue
        spotAt = placed.spotAt
      }
      problem = Self.notKept
      return
    }
    for file in files { thumbnails[file.id] = nil }
    waiting = await outbox.waiting
    await send()
  }

  static let notKept = "This phone couldn't save that to send, so nothing was sent. Free up some space and try again."

  /// Queues any other write, so it goes under one key however many times it
  /// is sent. False when the phone couldn't keep it.
  private func queue(_ operation: OutboxOperation) async -> Bool {
    do {
      try await outbox.enqueue(operation)
    } catch {
      problem = Self.notKept
      return false
    }
    waiting = await outbox.waiting
    await send()
    return true
  }

  func send() async {
    guard let client else { return }
    let report = await outbox.flush(prepare: { item, folder throws(APIError) in
      try await client.prepare(item, files: folder)
    }) { item throws(APIError) in try await client.perform(item) }
    waiting = await outbox.waiting
    for sent in report.sent {
      if case .pinned(let answer) = sent.result { tags = answer }
    }
    if let last = report.filed.last {
      lastFiled = last
      let badges = report.filed.flatMap { $0.unlocked ?? [] }
      toast = badges.isEmpty ? "Filed in \(last.note.version)." : "Unlocked: \(badges.map(\.name).joined(separator: ", "))"
      if last.note.date == me?.today { me?.wroteToday = true }
    }
    if report.sent.contains(where: { $0.item.text != nil || $0.result == .deleted }) { await loadToday() }
    if let stopped = report.stopped { handle(stopped) }
  }

  func discard(_ item: OutboxItem) async {
    await outbox.discard(item.id)
    waiting = await outbox.waiting
  }

  /// A refused note, fixed by hand. False when the phone couldn't keep it.
  func retry(_ item: OutboxItem, text: String) async -> Bool {
    do { try await outbox.retry(item.id, text: text) } catch {
      problem = Self.notKept
      return false
    }
    waiting = await outbox.waiting
    await send()
    return true
  }

  func clearToast() { toast = nil }

  // MARK: Files

  var canAddFiles: Bool { me?.token.scopes.contains("media:write") == true }
  var roomForFiles: Int { max(0, MediaType.maxFiles - draftFiles.count) }

  /// A photo from the library or the camera: JPEG, PNG, GIF and WebP as
  /// they are, anything else made a JPEG with its time and place kept.
  func addPhoto(_ data: Data?) async {
    let made = await Task.detached { () -> (data: Data, type: String, thumbnail: CGImage?)? in
      guard let data, let photo = MediaType.photo(data) else { return nil }
      return (photo.data, photo.type, MediaType.thumbnail(photo.data))
    }.value
    guard let made else {
      problem = "That photo couldn't be read."
      return
    }
    let n = draftFiles.filter(\.isPhoto).count + 1
    await addFile(made.data, type: made.type, name: "Photo \(n).\(MediaType.fileExtension(made.type))", thumbnail: made.thumbnail)
  }

  func addRecording(_ data: Data) async {
    let n = draftFiles.filter(\.isRecording).count + 1
    await addFile(data, type: "audio/mp4", name: n == 1 ? "Voice memo.m4a" : "Voice memo \(n).m4a", thumbnail: nil)
  }

  private func addFile(_ data: Data, type: String, name: String, thumbnail: CGImage?) async {
    guard roomForFiles > 0 else {
      problem = "A note holds up to \(MediaType.maxFiles) files."
      return
    }
    guard data.count <= MediaType.maxBytes else {
      problem = "That file is over 50 MB, the most a note keeps."
      return
    }
    let file = QueuedFile(type: type, name: name, size: data.count)
    let outbox = self.outbox
    let kept = await Task.detached { () -> Bool in
      do { try outbox.keep(data, as: file); return true } catch { return false }
    }.value
    guard kept else {
      problem = Self.notKept
      return
    }
    draftFiles.append(file)
    thumbnails[file.id] = thumbnail
    problem = nil
    await draftStarted()
  }

  func remove(_ file: QueuedFile) {
    draftFiles.removeAll { $0.id == file.id }
    thumbnails[file.id] = nil
    outbox.removeFiles([file])
  }

  // MARK: Here

  /// What the draft's place will be named, if it has one.
  var placeLabel: String? {
    guard !placeOff, spot != nil else { return nil }
    return venue ?? here?.place.label ?? "Here"
  }

  /// A new draft: with "Add where I am" on, find the phone now, while the
  /// words are typed, so the note never waits for it. A spot more than ten
  /// minutes old is found again.
  func draftStarted() async {
    guard hereByDefault, !placeOff, !locating else { return }
    if let spotAt, spotAt > .now.addingTimeInterval(-600) { return }
    await locate()
  }

  /// Finds the phone and has Release Notes name the spot, with the
  /// businesses nearby. Offline, the spot is kept and named when it sends.
  func locate() async {
    guard !locating else { return }
    locating = true
    defer { locating = false }
    placeOff = false
    switch await Locator.spot() {
    case .denied:
      problem = "Location is off for Changelog. Allow it in the Settings app to add where you are."
    case .unavailable:
      problem = "This phone couldn't find where it is just now."
    case .spot(let found):
      spot = found
      spotAt = .now
      here = nil
      venue = nil
      guard let client else { return }
      do {
        let named = try await client.here(found)
        // The owner may have left it off, or committed, while it was named.
        if spot == found { here = named }
      } catch {
        if error.signedOut { return handle(error) }
        if error.retryable && error.status != 429 { return }
        // Nowhere a city can be named (at sea), or the day's spots used.
        if spot == found { clearPlace(off: true) }
        problem = error.message
      }
    }
  }

  /// A business nearby, or nil for the neighbourhood or city alone.
  func pick(venue name: String?) {
    venue = name
  }

  /// Leaves the place off this draft (`off`), or clears it once a note took it.
  func clearPlace(off: Bool = true) {
    spot = nil
    here = nil
    venue = nil
    spotAt = nil
    placeOff = off
  }

  // MARK: Notes this token wrote

  /// Whether a row is a note this phone's token wrote, the only ones it may
  /// change.
  func isMine(_ item: ActivityItem) -> Bool {
    item.kind == "note.added" && item.via == "token" && item.token == me?.token.name && item.note != nil
  }

  func load(_ item: ActivityItem) async -> NoteDetail? {
    guard let client, let day = item.day, let id = item.note else { return nil }
    do { return try await client.note(date: day, id: id) } catch { handle(error); return nil }
  }

  /// Queues an edit from the revision read. True once it is safely queued:
  /// a refusal (changed since) shows under Waiting to send.
  func save(_ note: NoteDetail, text: String) async -> Bool {
    await queue(.edit(date: note.date, id: note.id, text: text, revision: note.revision))
  }

  func delete(_ item: ActivityItem) async {
    guard let day = item.day, let id = item.note else { return }
    _ = await queue(.delete(date: day, id: id))
  }

  // MARK: Tags

  func toggle(_ tag: String) {
    draft = Hashtags.toggling(tag, in: draft)
  }

  func toggleSticky(_ tag: String) {
    sticky = sticky == tag ? nil : tag
  }

  /// Shows the new pins at once; Release Notes' answer replaces them.
  func setPinned(_ pinned: [String]) async {
    let before = tags
    tags?.pinned = pinned
    if !(await queue(.pins(pinned))) { tags = before }
  }

  // MARK: Activity

  func activity(before: String? = nil, kinds: [String] = []) async -> ActivityPage? {
    guard let client else { return nil }
    do { return try await client.activity(before: before, kinds: kinds) } catch { handle(error); return nil }
  }

  private func handle(_ error: APIError) {
    if error.signedOut {
      forget()
      problem = error.message
    } else if error.status == 0 {
      problem = nil // Offline: notes wait in the queue, quietly.
    } else {
      problem = error.message
    }
  }
}
