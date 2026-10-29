import ChangelogKit
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
  var draft = ""

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
    #if DEBUG
    // `simctl launch` with SIMCTL_CHILD_CHANGELOG_DEV_TOKEN signs a debug
    // build in to the dev server's fictional account (AGENTS.md, Building).
    if token == nil, let dev = ProcessInfo.processInfo.environment["CHANGELOG_DEV_TOKEN"] {
      server = APIClient.devServer
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

  // MARK: Writing

  var canCommit: Bool {
    !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  /// Queues the draft with the moment it was typed, then tries to send. If
  /// the phone can't keep the queue, the words go back in the box.
  func commit() async {
    let typed = draft
    var text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    if let sticky { text = Hashtags.adding(sticky, to: text) }
    draft = ""
    do {
      try await outbox.enqueue(text: text)
    } catch {
      draft = draft.isEmpty ? typed : typed + "\n" + draft
      problem = Self.notKept
      return
    }
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
    let report = await outbox.flush { item throws(APIError) in try await client.perform(item) }
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
