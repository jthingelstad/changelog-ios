import ChangelogKit
import CoreGraphics
import Foundation
import Observation
import UIKit
import WidgetKit

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
  /// The words of today's notes this token wrote, by note id, read back on
  /// each refresh (`TodayWords`). In memory only.
  private var todayWords: [String: String] = [:]
  /// Each read of Today, so one that finishes after a newer read (or after
  /// signing out) changes nothing.
  private var todayGeneration = 0
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
  /// The daily prompt, off by default.
  private(set) var promptOn: Bool
  private(set) var promptProblem: String?
  /// The activity this phone tells of, each kind chosen in Settings; none
  /// until then.
  private(set) var activityNotices: Set<ActivityNoticeKind>
  private(set) var activityProblem: String?
  /// The draft, with its files and place below, is kept on this phone as
  /// it changes (`DraftStore`), so a relaunch finds it.
  var draft = "" {
    didSet { if draft != oldValue { keepDraftSoon() } }
  }
  /// Files on the draft, their bytes already beside the queue.
  private(set) var draftFiles: [QueuedFile] = [] {
    didSet { keepDraftSoon() }
  }
  /// Small pictures of the draft's photos, for the composer only.
  private(set) var thumbnails: [UUID: CGImage] = [:]

  /// Where the draft was written: the phone's spot, and the place Release
  /// Notes named for it (nil offline, named when the note is sent).
  private(set) var spot: Spot? {
    didSet { keepDraftSoon() }
  }
  private(set) var here: Here? {
    didSet { keepDraftSoon() }
  }
  /// A business nearby the owner picked, if any.
  private(set) var venue: String? {
    didSet { keepDraftSoon() }
  }
  private(set) var locating = false
  private var spotAt: Date?
  /// The owner left the place off this draft.
  private var placeOff = false {
    didSet { keepDraftSoon() }
  }
  /// The spot a Here under way is naming, and the notes committed meanwhile,
  /// which that Here names when it answers rather than a second lookup.
  private var naming: Spot?
  private var waitingOnName: [UUID] = []

  /// "Add where I am": every note gets a place without asking. Kept on
  /// this phone; each Here is a lookup Release Notes pays for.
  var hereByDefault: Bool {
    didSet { defaults.set(hereByDefault, forKey: "here") }
  }

  /// A tag that rides on every note until turned off (a trip, a project).
  /// Kept on this phone only: a habit of the moment, not a setting.
  var sticky: String? {
    didSet {
      defaults.set(sticky, forKey: "sticky")
      AppGroup.defaults?.set(sticky, forKey: "sticky")
    }
  }

  /// The share extension reads the server and the sticky tag from the App
  /// Group, so a shared note goes where the app's do, tagged as they are.
  var server: URL {
    didSet {
      defaults.set(server.absoluteString, forKey: "server")
      AppGroup.defaults?.set(server.absoluteString, forKey: "server")
    }
  }

  private let tokens: TokenStore
  private let outbox: Outbox
  private let drafts: DraftStore
  private let defaults: UserDefaults
  private var token: String?
  /// Nothing is kept until the draft kept before is back, so a launch (a
  /// background refresh among them) can't write an empty box over it.
  @ObservationIgnored private var draftRestored = false
  /// Commits putting the draft in the queue: until it is there, the draft
  /// kept stays as it was.
  @ObservationIgnored private var committing = 0
  @ObservationIgnored private var keeping: Task<Void, Never>?

  init(tokens: TokenStore = KeychainTokenStore(accessGroup: AppGroup.id), defaults: UserDefaults = .standard,
       outboxFile: URL? = AppModel.outboxFile) {
    self.tokens = tokens
    self.defaults = defaults
    self.outbox = Outbox(file: outboxFile)
    self.drafts = DraftStore(file: outboxFile?.deletingLastPathComponent().appending(path: "draft.json"))
    self.sticky = defaults.string(forKey: "sticky")
    self.remindersOn = defaults.bool(forKey: "reminders")
    self.promptOn = defaults.bool(forKey: "prompt")
    self.activityNotices = Set((defaults.stringArray(forKey: "activity.notices") ?? []).compactMap(ActivityNoticeKind.init(rawValue:)))
    self.hereByDefault = defaults.bool(forKey: "here")
    #if DEBUG
    self.server = defaults.string(forKey: "server").flatMap(URL.init(string:)) ?? APIClient.production
    #else
    // A release build talks to Release Notes alone, whatever a debug build
    // on this phone left saved.
    self.server = APIClient.production
    #endif
    AppGroup.defaults?.set(server.absoluteString, forKey: "server")
    AppGroup.defaults?.set(sticky, forKey: "sticky")
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
    // A token an earlier build kept where only the app could read it moves
    // to the App Group, for the share extension.
    (tokens as? KeychainTokenStore)?.share()
    token = tokens.read()
    // The draft a run that ended left (iOS ends an app it isn't showing),
    // and shares the extension couldn't send, come in first, so the sweep
    // after keeps their files.
    restoreDraft()
    await adoptShares()
    // Files nothing holds, left by a run that ended; the queue's own stay.
    await outbox.sweep(keeping: Set(draftFiles.map(\.id)))
    #if DEBUG
    // `simctl launch` with SIMCTL_CHILD_CHANGELOG_DEV_TOKEN (or a UI test)
    // signs a debug build in to the dev server's fictional account
    // (AGENTS.md, Building). It always wins over a token kept from before,
    // so a run meant for the dev server never writes anywhere else.
    // CHANGELOG_DEV_URL picks another port, on this Mac only.
    let environment = ProcessInfo.processInfo.environment
    if let dev = environment["CHANGELOG_DEV_TOKEN"] {
      let other = environment["CHANGELOG_DEV_URL"].flatMap(URL.init(string:))
      server = other.flatMap { ["localhost", "127.0.0.1"].contains($0.host() ?? "") ? $0 : nil } ?? APIClient.devServer
      token = nil
      problem = await signIn(with: dev)
      if problem == nil { return }
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
    return await keep(candidate)
  }

  /// Signs in on Release Notes' own page, which `authenticate` shows (the
  /// sign-in sheet) and answers the app's callback from, or nil when the
  /// sheet was closed. The owner names the token there and chooses what it
  /// may do; it comes back kept as a pasted one is. Nil when signed in, or
  /// when the owner chose Cancel; else what went wrong.
  func signInWithReleaseNotes(through authenticate: (URL) async throws -> URL?) async -> String? {
    let flow = SignIn(server: server, userAgent: Self.userAgent)
    let clientID: String
    do throws(SignInError) { clientID = try await flow.register() } catch { return error.message }
    let callback: URL?
    do { callback = try await authenticate(flow.authorizeURL(clientID: clientID)) } catch {
      return "The sign-in page couldn't open. Try again, or use a token."
    }
    guard let callback else { return nil }
    let grant: SignIn.Grant
    do throws(SignInError) {
      guard let code = try flow.code(from: callback) else { return nil }
      grant = try await flow.exchange(code: code, clientID: clientID)
    } catch { return error.message }
    guard let problem = await keep(grant.accessToken) else { return nil }
    // A token this sign-in made that the app can't keep is ended, not left
    // behind in the owner's list.
    try? await APIClient(baseURL: server, token: grant.accessToken, userAgent: Self.userAgent).revokeToken()
    return grant.scope.split(separator: " ").contains("notes:write")
      ? problem : "Changelog needs “Add notes” to send notes. Sign in again with it ticked."
  }

  private func keep(_ candidate: String) async -> String? {
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
  /// stay on the phone for the next sign-in. When Release Notes can't be
  /// reached to end the token, the sign-in screen says to end it on the web.
  func signOut() async {
    var ended = true
    if let client {
      do throws(APIError) { try await client.revokeToken() } catch { ended = error.signedOut }
    }
    forget()
    if !ended { problem = Self.notEnded }
  }

  static let notEnded = "Changelog signed out, but Release Notes couldn't be reached to end its token. End it on the web, under Settings, API tokens."

  private func forget() {
    tokens.clear()
    token = nil
    me = nil
    tags = nil
    today = []
    todayWords = [:]
    todayGeneration += 1
    phase = .signedOut
    // The next sign-in asks again before any reminder comes.
    remindersOn = false
    remindersGeneration += 1
    defaults.set(false, forKey: "reminders")
    promptOn = false
    defaults.set(false, forKey: "prompt")
    activityNotices = []
    defaults.removeObject(forKey: "activity.notices")
    defaults.removeObject(forKey: Self.activityCursor)
    soon = nil
    WidgetSnapshot.clear()
    WidgetCenter.shared.reloadAllTimelines()
    PhoneReminders.clearShown()
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
      await readSoon()
      updateWidgets()
      await loadToday()
      await send()
      await updateReminders()
    } catch let error as APIError {
      handle(error)
    } catch {}
  }

  private func loadToday() async {
    guard let client, let me, me.token.scopes.contains("activity") else { return }
    todayGeneration += 1
    let generation = todayGeneration
    guard let page = try? await client.activity(limit: 100), generation == todayGeneration else { return }
    today = page.items.filter { $0.day == me.today || ($0.day == nil && $0.at.hasPrefix(me.today)) }
    let mine = today.filter(isMine).compactMap { item in
      item.day.flatMap { day in item.note.map { TodayWords.Note(date: day, id: $0) } }
    }
    let words = await TodayWords.read(mine, keeping: todayWords) { note throws(APIError) in
      try await client.note(date: note.date, id: note.id).text
    }
    if generation == todayGeneration { todayWords = words }
  }

  // MARK: Reminders and the daily prompt

  var canRemind: Bool { me?.token.scopes.contains("upcoming") == true }

  /// The Settings toggle. Turning it on asks iOS first; if notifications are
  /// off for Changelog it stays off and says where to allow them.
  func setReminders(_ on: Bool) async {
    remindersGeneration += 1
    remindersProblem = nil
    if on, !(await PhoneReminders.ask()) {
      remindersProblem = Self.notificationsOff
      return await updateReminders()
    }
    remindersOn = on
    defaults.set(on, forKey: "reminders")
    await updateReminders()
  }

  /// The daily prompt's toggle, asking iOS first as reminders do.
  func setPrompt(_ on: Bool) async {
    remindersGeneration += 1
    promptProblem = nil
    if on, !(await PhoneReminders.ask()) {
      promptProblem = Self.notificationsOff
      return await updateReminders()
    }
    promptOn = on
    defaults.set(on, forKey: "prompt")
    await updateReminders()
  }

  static let notificationsOff = "Notifications are off for Changelog. Allow them in the Settings app, then turn this on again."

  /// Replaces this phone's reminders and daily prompts from a fresh read,
  /// within iOS's limit on waiting notifications (`NotificationPlan`).
  /// Offline, the reminders scheduled stay and the prompts are topped up
  /// from the last `/v1/me`; a token that can't read Upcoming clears its
  /// reminders.
  func updateReminders() async {
    let generation = remindersGeneration
    guard token != nil, remindersOn || promptOn else { return await stopReminders() }
    // A background launch that couldn't reach /v1/me doesn't know the
    // token's scopes or the days ahead yet, which is not the same as lacking
    // them: keep what is scheduled and try again later.
    guard let me else { return scheduleRefresh() }
    let allowed = await PhoneReminders.allowed()
    remindersProblem = remindersOn && !allowed ? Self.notificationsOff : nil
    promptProblem = promptOn && !allowed ? Self.notificationsOff : nil
    var answer: Reminders?
    var reminders: [PlannedReminder]? = []
    if remindersOn, me.token.scopes.contains("upcoming"), let client {
      do {
        answer = try await client.reminders()
        reminders = answer.map { ReminderPlan.plan($0, now: .now) }
      } catch {
        // Unreachable: what is waiting stays. Revoked, or no longer allowed
        // to read Upcoming: the reminders go.
        if !(error.signedOut || error.code == "scope_required") { reminders = nil }
      }
    }
    guard wantsNotifications(generation) else { return }
    let prompts = promptOn ? DailyPrompt.plan(me, reminders: answer, now: .now) : []
    await PhoneReminders.schedule(reminders: reminders, prompts: prompts) { self.wantsNotifications(generation) }
    if wantsNotifications(generation) { scheduleRefresh() }
  }

  /// Whether an update begun at `generation` still speaks for the toggles.
  private func wantsNotifications(_ generation: Int) -> Bool {
    generation == remindersGeneration && token != nil && (remindersOn || promptOn)
  }

  private func stopReminders() async {
    await PhoneReminders.clear()
    scheduleRefresh()
  }

  /// A background refresh while anything needs one: sooner for activity,
  /// which only a refresh reads; none once everything is off.
  private func scheduleRefresh() {
    guard token != nil, remindersOn || promptOn || !activityNotices.isEmpty else { return PhoneReminders.cancelRefresh() }
    PhoneReminders.askForRefresh(after: activityNotices.isEmpty ? 6 * 3600 : 3600)
  }

  /// iOS's background refresh, which may start the app without a window:
  /// read who this is, send what waits, read the reminders again, and look
  /// for activity to tell of.
  func backgroundRefresh() async {
    if token == nil { token = tokens.read() }
    guard let client else { return }
    do {
      me = try await client.me()
      await readSoon()
      updateWidgets()
    } catch {
      // A revoked or expired token signs out here as it would on screen.
      if error.signedOut { return handle(error) }
    }
    await send()
    await updateReminders()
    await notifyActivity()
  }

  // MARK: Activity notifications

  /// The newest activity row already told of (or passed over), kept on this
  /// phone only, apart from Activity's "since you last looked".
  static let activityCursor = "activity.notified"

  func setActivityNotice(_ kind: ActivityNoticeKind, _ on: Bool) async {
    activityProblem = nil
    if on, !(await PhoneReminders.ask()) {
      activityProblem = Self.notificationsOff
      return
    }
    let wasOff = activityNotices.isEmpty
    if on { activityNotices.insert(kind) } else { activityNotices.remove(kind) }
    defaults.set(activityNotices.map(\.rawValue).sorted(), forKey: "activity.notices")
    // Turned on: only what happens from now on is news.
    if activityNotices.isEmpty || wasOff { defaults.removeObject(forKey: Self.activityCursor) }
    if wasOff, !activityNotices.isEmpty { await startActivityCursor() }
    scheduleRefresh()
  }

  /// Marks the newest row as seen, telling of nothing before it.
  private func startActivityCursor() async {
    guard let client, me?.token.scopes.contains("activity") == true,
          let page = try? await client.activity(kinds: ActivityNotices.families, limit: 1) else { return }
    defaults.set(page.items.first?.id ?? "", forKey: Self.activityCursor)
  }

  /// Reads what happened since the last look and shows the kinds chosen.
  /// Rows past the first 100 new ones are passed over, with their kinds
  /// already summed in what shows.
  func notifyActivity() async {
    let wanted = activityNotices
    guard !wanted.isEmpty, let client, let me, me.token.scopes.contains("activity") else { return }
    guard let cursor = defaults.string(forKey: Self.activityCursor) else { return await startActivityCursor() }
    let page: ActivityPage
    do {
      page = try await client.activity(after: cursor.isEmpty ? nil : cursor, kinds: ActivityNotices.families, limit: 100)
    } catch {
      if error.signedOut { handle(error) }
      return
    }
    // Turned off, or signed out, while the read was out.
    guard activityNotices == wanted, token != nil, defaults.string(forKey: Self.activityCursor) == cursor else { return }
    if let next = ActivityNotices.cursor(after: page.items, previous: cursor) { defaults.set(next, forKey: Self.activityCursor) }
    guard await PhoneReminders.allowed() else { return }
    await PhoneReminders.show(ActivityNotices.notices(for: page.items, tokenName: me.token.name, wanted: wanted))
  }

  // MARK: Upcoming

  /// Upcoming needs the `upcoming` scope, as reminders do. The app never
  /// changes a token's scopes; the web makes a new token.
  var canKeepUpcoming: Bool { canRemind }

  func upcoming() async throws(APIError) -> UpcomingList {
    guard let client else { throw .notSignedIn }
    do {
      let list = try await client.upcoming()
      soon = WidgetSnapshot.soonest(list.entries)
      updateWidgets()
      return list
    } catch {
      if error.signedOut { handle(error) }
      throw error
    }
  }

  /// Saves at once, under the key the caller holds for this request, so a
  /// Save tapped again after a lost answer is the same save. Upcoming isn't
  /// queued: a change is made from a revision, and a refusal (a city the
  /// search doesn't know) is for the person to fix there and then.
  func saveUpcoming(_ batch: UpcomingBatch, idempotencyKey: String?) async throws(APIError) -> UpcomingSaved {
    guard let client else { throw .notSignedIn }
    do {
      let saved = try await client.saveUpcoming(batch, idempotencyKey: idempotencyKey)
      if !batch.dryRun { Task { await updateReminders() } }
      return saved
    } catch {
      if error.signedOut { handle(error) }
      throw error
    }
  }

  func deleteUpcoming(_ entry: UpcomingEntry, idempotencyKey: String) async throws(APIError) {
    guard let client else { throw .notSignedIn }
    do {
      try await client.deleteUpcoming(id: entry.id, revision: entry.revision, idempotencyKey: idempotencyKey)
      Task { await updateReminders() }
    } catch {
      if error.signedOut { handle(error) }
      throw error
    }
  }

  // MARK: Widgets

  /// The next Upcoming dates the widgets show: kept from the last read, so
  /// a read that fails leaves them be. Nil for a token that can't read
  /// Upcoming.
  @ObservationIgnored private var soon: [WidgetSnapshot.Soon]? = WidgetSnapshot.load()?.upcoming

  private func readSoon() async {
    guard let client, me?.token.scopes.contains("upcoming") == true else {
      soon = nil
      return
    }
    if let list = try? await client.upcoming() { soon = WidgetSnapshot.soonest(list.entries) }
  }

  /// Writes what the widgets show to the App Group, and has them drawn
  /// again when it changed. Never a note's words.
  private func updateWidgets() {
    guard let me else { return }
    let snapshot = WidgetSnapshot(me: me, soon: soon)
    guard snapshot != WidgetSnapshot.load() else { return }
    snapshot.save()
    WidgetCenter.shared.reloadAllTimelines()
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
    committing += 1
    if let sticky { text = Hashtags.adding(sticky, to: text) }
    let placed = (spot: placeOff ? nil : spot, here: here, venue: venue, spotAt: spotAt)
    var place = placed.here?.place
    place?.venue = placed.venue
    draft = ""
    draftFiles = []
    // With "Add where I am" on, the next note within ten minutes takes the
    // same place; a Here asked for once goes with this note alone.
    if hereByDefault { placeOff = false } else { clearPlace(off: false) }
    let item: OutboxItem
    do {
      if files.isEmpty && placed.spot == nil {
        item = try await outbox.enqueue(text: text)
      } else {
        item = try await outbox.enqueue(.post(NotePost(text: text, writtenAt: Timestamp.string(.now), files: files,
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
      committing -= 1
      keepDraft()
      problem = Self.notKept
      return
    }
    // In the queue: what is kept now is what's left in the box.
    committing -= 1
    keepDraft()
    for file in files { thumbnails[file.id] = nil }
    waiting = await outbox.waiting
    // Here is still naming this spot: that answer names the note, then sends.
    if let spot = placed.spot, place == nil, naming == spot {
      waitingOnName.append(item.id)
      return
    }
    await send()
  }

  /// Why Changelog signed itself out, for the sign-in screen.
  static func signedOutReason(_ error: APIError) -> String {
    switch error.code {
    case "token_revoked": "This phone's token was revoked, so Changelog signed out. Sign in again."
    case "token_expired": "This phone's token expired, so Changelog signed out. Sign in again."
    default: error.message
    }
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

  /// Takes in notes shared from other apps that the share extension left.
  private func adoptShares() async {
    await ShareInbox.shared?.adopt(into: outbox)
    waiting = await outbox.waiting
  }

  func send() async {
    guard let client else { return }
    await adoptShares()
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
      if last.note.date == me?.today {
        me?.wroteToday = true
        updateWidgets()
      }
      // Written today: today's prompt has nothing left to ask.
      if promptOn, report.filed.contains(where: { $0.note.date == me?.today }), let today = me?.today {
        PhoneReminders.takeBack([DailyPrompt.id(today)])
      }
    }
    if report.sent.contains(where: { $0.item.text != nil || $0.result == .deleted }) { await loadToday() }
    if let stopped = report.stopped { handle(stopped) }
  }

  func discard(_ item: OutboxItem) async {
    await outbox.discard(item.id)
    waiting = await outbox.waiting
  }

  /// A refused note or edit, fixed by hand: a note with the files it still
  /// goes with, an edit from the revision read again. False when the phone
  /// couldn't keep it.
  func retry(_ item: OutboxItem, text: String, keeping files: Set<UUID>? = nil, revision: String? = nil) async -> Bool {
    do { try await outbox.retry(item.id, text: text, keeping: files, revision: revision) } catch {
      problem = Self.notKept
      return false
    }
    waiting = await outbox.waiting
    await send()
    return true
  }

  func clearToast() { toast = nil }

  // MARK: Keeping the draft

  /// Keeps the draft a moment after it last changed, so typing doesn't
  /// write on every letter.
  private func keepDraftSoon() {
    guard draftRestored, committing == 0 else { return }
    keeping?.cancel()
    keeping = Task {
      try? await Task.sleep(for: .seconds(1))
      if !Task.isCancelled { keepDraft() }
    }
  }

  /// Keeps the draft now: as the app leaves the screen, and once a commit
  /// has put it in the queue. Never logged; a draft the phone can't write
  /// is still in the box.
  func keepDraft() {
    keeping?.cancel()
    guard draftRestored, committing == 0 else { return }
    drafts.save(Draft(text: draft, files: draftFiles, spot: spot, here: here, venue: venue, spotAt: spotAt, placeOff: placeOff))
  }

  /// Puts back the draft a run that ended left, and its photos' pictures.
  private func restoreDraft() {
    guard !draftRestored else { return }
    defer { draftRestored = true }
    guard let kept = drafts.load(filesIn: outbox) else { return }
    draft = kept.text
    draftFiles = kept.files
    spot = kept.spot
    here = kept.here
    venue = kept.venue
    spotAt = kept.spotAt
    placeOff = kept.placeOff
    let outbox = self.outbox
    for file in kept.files where file.isPhoto {
      Task {
        let thumbnail = await Task.detached {
          outbox.url(for: file).flatMap { try? Data(contentsOf: $0) }.flatMap { MediaType.thumbnail($0) }
        }.value
        if draftFiles.contains(where: { $0.id == file.id }) { thumbnails[file.id] = thumbnail }
      }
    }
    // Ended before the phone was found: with "Add where I am" on, it is
    // found now, as for any draft begun.
    if spot == nil, token != nil { Task { await draftStarted() } }
  }

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
      naming = found
      let answer: Result<Here, APIError>
      do { answer = .success(try await client.here(found)) } catch { answer = .failure(error) }
      naming = nil
      let queued = waitingOnName
      waitingOnName = []
      switch answer {
      case .success(let named):
        // The owner may have left it off, or committed, while it was named.
        if spot == found { here = named }
        for id in queued { await outbox.name(id, spot: found, place: named.place) }
      case .failure(let error):
        if error.signedOut { return handle(error) }
        // Offline: the note names its spot as it sends.
        guard !error.retryable || error.status == 429 else { break }
        // Nowhere a city can be named (at sea), or the day's spots used.
        if spot == found { clearPlace(off: true) }
        problem = error.message
        for id in queued { await outbox.name(id, spot: found, place: nil) }
      }
      if !queued.isEmpty {
        waiting = await outbox.waiting
        await send()
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

  /// What a row of Today said, when it is a note this token wrote and its
  /// words have been read back. Only Log shows them.
  func words(of item: ActivityItem) -> String? {
    isMine(item) ? item.note.flatMap { todayWords[$0] } : nil
  }

  /// Reads a note this token wrote, to edit it. A token that no longer
  /// works signs out; any other failure is for the editor to say.
  func load(date: String, id: String) async throws(APIError) -> NoteDetail {
    guard let client else { throw .notSignedIn }
    do { return try await client.note(date: date, id: id) } catch {
      if error.signedOut { handle(error) }
      throw error
    }
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
      problem = Self.signedOutReason(error)
    } else if error.status == 0 {
      problem = nil // Offline: notes wait in the queue, quietly.
    } else {
      problem = error.message
    }
  }
}
