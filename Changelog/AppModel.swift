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
    phase = token == nil ? .signedOut : .signedIn
    if phase == .signedIn { await refresh() }
  }

  /// Checks a pasted or scanned token with `/v1/me` before keeping it.
  func signIn(with raw: String) async -> String? {
    guard let candidate = TokenFormat.extract(raw) else {
      return "That isn't a Release Notes token. It starts with rn_."
    }
    let probe = APIClient(baseURL: server, token: candidate, userAgent: Self.userAgent)
    do {
      let me = try await probe.me()
      guard me.token.scopes.contains("notes:write") else {
        return "This token can't add notes. Make one with Add notes ticked."
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

  /// Queues the draft with the moment it was typed, then tries to send.
  func commit() async {
    var text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    if let sticky { text = Hashtags.adding(sticky, to: text) }
    draft = ""
    await outbox.enqueue(text: text)
    waiting = await outbox.waiting
    await send()
  }

  func send() async {
    guard let client else { return }
    let report = await outbox.flush { item throws(APIError) in
      try await client.createNote(item.request, idempotencyKey: item.idempotencyKey)
    }
    waiting = await outbox.waiting
    if let last = report.sent.last {
      lastFiled = last.receipt
      let badges = report.sent.flatMap { $0.receipt.unlocked ?? [] }
      toast = badges.isEmpty ? "Filed in \(last.receipt.note.version)." : "Unlocked: \(badges.map(\.name).joined(separator: ", "))"
      await loadToday()
      if last.receipt.note.date == me?.today { me?.wroteToday = true }
    }
    if let stopped = report.stopped { handle(stopped) }
  }

  func discard(_ item: OutboxItem) async {
    await outbox.discard(item.id)
    waiting = await outbox.waiting
  }

  func retry(_ item: OutboxItem, text: String) async {
    await outbox.retry(item.id, text: text)
    waiting = await outbox.waiting
    await send()
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

  func save(_ note: NoteDetail, text: String) async -> Bool {
    guard let client else { return false }
    do {
      _ = try await client.editNote(date: note.date, id: note.id, text: text, revision: note.revision,
                                    idempotencyKey: UUID().uuidString.lowercased())
      await loadToday()
      return true
    } catch {
      handle(error)
      return false
    }
  }

  func delete(_ item: ActivityItem) async {
    guard let client, let day = item.day, let id = item.note else { return }
    do {
      try await client.deleteNote(date: day, id: id, idempotencyKey: UUID().uuidString.lowercased())
      await loadToday()
    } catch { handle(error) }
  }

  // MARK: Tags

  func toggle(_ tag: String) {
    draft = Hashtags.toggling(tag, in: draft)
  }

  func toggleSticky(_ tag: String) {
    sticky = sticky == tag ? nil : tag
  }

  func setPinned(_ pinned: [String]) async {
    guard let client else { return }
    do { tags = try await client.setPinned(pinned, idempotencyKey: UUID().uuidString.lowercased()) } catch { handle(error) }
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
