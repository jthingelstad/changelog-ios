import ChangelogKit
import CoreGraphics
import Foundation
import Observation
import UIKit
import UniformTypeIdentifiers

/// A share, from the items another app handed over to a note in Release
/// Notes. It goes through a queue of its own in the App Group: sent from
/// here if it can be, else left for the app, which sends it under the same
/// key. Nothing a note says is logged.
@MainActor @Observable
final class ShareModel {
  enum Phase: Equatable { case loading, ready, sending, done(String) }

  var text = ""
  private(set) var files: [QueuedFile] = []
  private(set) var thumbnails: [UUID: CGImage] = [:]
  /// Items Release Notes doesn't keep (a video, a spreadsheet), left out.
  private(set) var skipped = 0
  private(set) var phase: Phase = .loading
  private(set) var problem: String?

  private let inbox = ShareInbox.shared
  private let share: (outbox: Outbox, file: URL)?
  private let finish: () -> Void

  init(finish: @escaping () -> Void) {
    self.finish = finish
    share = inbox?.open()
  }

  var canCommit: Bool {
    phase == .ready && (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !files.isEmpty)
  }

  // MARK: What was shared

  func load(_ items: [NSExtensionItem]) async {
    var words: [String] = []
    for item in items {
      if let said = item.attributedContentText?.string.trimmingCharacters(in: .whitespacesAndNewlines), !said.isEmpty {
        words.append(said)
      }
      for provider in item.attachments ?? [] {
        if let line = await take(provider) { words.append(line) }
      }
    }
    text = words.joined(separator: "\n")
    phase = share == nil ? .done(Self.noGroup) : .ready
  }

  /// One shared item: a file kept for the note, or words (a link, text) to
  /// go in it. Answers the words.
  private func take(_ provider: NSItemProvider) async -> String? {
    guard files.count < MediaType.maxFiles else {
      skipped += 1
      return nil
    }
    if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
      // Photos are small enough to read whole. A JPEG or PNG the sharing
      // app has is taken as it is; anything else (a HEIC) is made a JPEG.
      let kind = Self.webImages.first { provider.registeredContentTypes.contains($0) } ?? .image
      guard let data = await Self.data(provider, kind),
            let photo = await Task.detached(operation: { MediaType.photo(data) }).value else {
        skipped += 1
        return nil
      }
      let n = files.filter(\.isPhoto).count + 1
      keep(photo.data, type: photo.type, name: "Photo \(n).\(MediaType.fileExtension(photo.type))",
           thumbnail: MediaType.thumbnail(photo.data))
      return nil
    }
    for (kind, type) in [(UTType.pdf, "application/pdf"), (UTType.mpeg4Audio, "audio/mp4")]
    where provider.hasItemConformingToTypeIdentifier(kind.identifier) {
      // Copied straight to the App Group, never read whole into memory.
      await copy(provider, kind, type: type)
      return nil
    }
    if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
       let url = await Self.url(provider), !url.isFileURL {
      return url.absoluteString
    }
    if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier), let words = await Self.text(provider) {
      return words
    }
    skipped += 1
    return nil
  }

  private func keep(_ data: Data, type: String, name: String, thumbnail: CGImage?) {
    guard let share, data.count <= MediaType.maxBytes else {
      skipped += 1
      return
    }
    let file = QueuedFile(type: type, name: name, size: data.count)
    do { try share.outbox.keep(data, as: file) } catch {
      skipped += 1
      return
    }
    files.append(file)
    thumbnails[file.id] = thumbnail
    inbox?.hold(files, for: share.file)
  }

  private func copy(_ provider: NSItemProvider, _ kind: UTType, type: String) async {
    guard let share, let folder = share.outbox.filesFolder else {
      skipped += 1
      return
    }
    let file = QueuedFile(type: type, name: Self.name(provider, kind), size: 0)
    guard let to = share.outbox.url(for: file) else { return }
    if let size = await Self.copy(provider, kind, into: folder, as: to), size > 0, size <= MediaType.maxBytes {
      var copied = file
      copied.size = size
      files.append(copied)
      inbox?.hold(files, for: share.file)
    } else {
      try? FileManager.default.removeItem(at: to)
      skipped += 1
    }
  }

  // MARK: Sending

  func commit() async {
    guard let share, let inbox, canCommit else { return }
    phase = .sending
    var words = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if let sticky = AppGroup.defaults?.string(forKey: "sticky") { words = Hashtags.adding(sticky, to: words) }
    do {
      try await share.outbox.enqueue(.post(NotePost(text: words, writtenAt: Timestamp.string(.now), files: files)))
    } catch {
      phase = .ready
      problem = "This phone couldn't save that to send. Free up some space and try again."
      return
    }
    guard let token = KeychainTokenStore(accessGroup: AppGroup.id).read() else {
      inbox.close(share.file, sent: false)
      return done("Saved. Open Changelog to send it.")
    }
    let server = AppGroup.defaults?.string(forKey: "server").flatMap(URL.init(string:)) ?? APIClient.production
    let client = APIClient(baseURL: server, token: token, userAgent: Self.userAgent)
    let outbox = share.outbox
    // The share sheet shouldn't hang: what isn't sent in time, the app sends.
    let sending = Task {
      await outbox.flush(prepare: { item, folder throws(APIError) in try await client.prepare(item, files: folder) }) {
        item throws(APIError) in try await client.perform(item)
      }
    }
    let timer = Task {
      try? await Task.sleep(for: .seconds(25))
      sending.cancel()
    }
    let report = await sending.value
    timer.cancel()
    let sent = await outbox.waiting.isEmpty
    inbox.close(share.file, sent: sent)
    if let receipt = report.filed.first {
      let badges = receipt.unlocked ?? []
      done(badges.isEmpty ? "Filed in \(receipt.note.version)." : "Unlocked: \(badges.map(\.name).joined(separator: ", "))")
    } else if let refused = report.refused.first?.refusal {
      done(refused + " It waits in Changelog to fix.")
    } else if report.stopped?.signedOut == true {
      done("Saved. Sign in to Changelog again and it goes from there.")
    } else {
      done("Saved. Changelog sends it when it can.")
    }
  }

  /// Before Commit, leaves without a note: the draft's files go. After it,
  /// only leaves: the note and its files wait for the app.
  func cancel() {
    switch phase {
    case .sending:
      return
    case .loading, .ready:
      if let share {
        share.outbox.removeFiles(files)
        try? FileManager.default.removeItem(at: share.file)
        inbox?.release(share.file)
      }
    case .done:
      break
    }
    leave()
  }

  private func done(_ said: String) {
    phase = .done(said)
    Task {
      try? await Task.sleep(for: .seconds(1.5))
      leave()
    }
  }

  private var left = false

  private func leave() {
    guard !left else { return }
    left = true
    finish()
  }

  private static let webImages: [UTType] = [.jpeg, .png, .gif, .webP]

  static let noGroup = "This build of Changelog can't take shares. Open Changelog and write the note there."

  static var userAgent: String {
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    return "Changelog/\(version) (iOS \(UIDevice.current.systemVersion))"
  }

  // MARK: Reading items

  private static func data(_ provider: NSItemProvider, _ kind: UTType) async -> Data? {
    await withCheckedContinuation { done in
      _ = provider.loadDataRepresentation(for: kind) { data, _ in done.resume(returning: data) }
    }
  }

  /// Copies the item's file into the App Group; answers its size.
  private static func copy(_ provider: NSItemProvider, _ kind: UTType, into folder: URL, as to: URL) async -> Int? {
    await withCheckedContinuation { done in
      _ = provider.loadFileRepresentation(for: kind, openInPlace: false) { from, _, _ in
        // The file is only there until this returns.
        guard let from else { return done.resume(returning: nil) }
        do {
          try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
          try FileManager.default.copyItem(at: from, to: to)
          done.resume(returning: (try FileManager.default.attributesOfItem(atPath: to.path(percentEncoded: false))[.size]) as? Int)
        } catch {
          done.resume(returning: nil)
        }
      }
    }
  }

  private static func url(_ provider: NSItemProvider) async -> URL? {
    await withCheckedContinuation { done in
      _ = provider.loadObject(ofClass: URL.self) { url, _ in done.resume(returning: url) }
    }
  }

  private static func text(_ provider: NSItemProvider) async -> String? {
    await withCheckedContinuation { done in
      _ = provider.loadObject(ofClass: String.self) { text, _ in
        done.resume(returning: text?.trimmingCharacters(in: .whitespacesAndNewlines))
      }
    }
  }

  private static func name(_ provider: NSItemProvider, _ kind: UTType) -> String {
    let ext = kind.preferredFilenameExtension ?? "bin"
    guard let suggested = provider.suggestedName, !suggested.isEmpty else {
      return kind == .pdf ? "Document.pdf" : "Voice memo.\(ext)"
    }
    return suggested.hasSuffix("." + ext) ? suggested : suggested + "." + ext
  }
}
