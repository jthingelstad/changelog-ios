import AVFoundation
import Observation

/// A voice memo: AAC in an .m4a, mono, which Release Notes keeps as
/// `audio/mp4`. At 64 kbit/s the 50 MB a file may be is over an hour and
/// a half, so recording stops itself before then.
@MainActor @Observable
final class Recorder {
  enum State: Equatable { case idle, recording, denied, failed }

  private(set) var state: State = .idle
  private var recorder: AVAudioRecorder?
  private var file: URL?
  private var starting = false
  private var stopped = false

  nonisolated static let longest: TimeInterval = 100 * 60

  var elapsed: TimeInterval { recorder?.currentTime ?? 0 }

  func start() async {
    guard state == .idle, !starting, !stopped else { return }
    starting = true
    defer { starting = false }
    guard await AVAudioApplication.requestRecordPermission() else {
      state = .denied
      return
    }
    let url = FileManager.default.temporaryDirectory.appending(path: "voice-\(UUID().uuidString.lowercased()).m4a")
    guard let recorder = await Self.record(to: url) else {
      try? FileManager.default.removeItem(at: url)
      state = .failed
      return
    }
    // Cancelled while it started: nothing keeps the microphone on.
    guard !stopped else {
      recorder.stop()
      Self.deactivate()
      try? FileManager.default.removeItem(at: url)
      return
    }
    self.recorder = recorder
    file = url
    state = .recording
  }

  /// Wakes the audio session and starts recording off the main thread: it
  /// can take a while (a headset joining, say), and the screen mustn't
  /// freeze for it.
  @concurrent private nonisolated static func record(to url: URL) async -> sending AVAudioRecorder? {
    let settings: [String: Any] = [
      AVFormatIDKey: kAudioFormatMPEG4AAC,
      AVSampleRateKey: 44_100,
      AVNumberOfChannelsKey: 1,
      AVEncoderBitRateKey: 64_000,
    ]
    do {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.record, mode: .default)
      try session.setActive(true)
      let recorder = try AVAudioRecorder(url: url, settings: settings)
      return recorder.record(forDuration: longest) ? recorder : nil
    } catch {
      return nil
    }
  }

  private nonisolated static func deactivate() {
    Task.detached { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
  }

  /// Stops and answers the recording's bytes; nil if there was none.
  func finish() -> Data? {
    guard let recorder, let file else { return nil }
    recorder.stop()
    self.recorder = nil
    self.file = nil
    state = .idle
    Self.deactivate()
    defer { try? FileManager.default.removeItem(at: file) }
    return try? Data(contentsOf: file)
  }

  func cancel() {
    stopped = true
    _ = finish()
  }
}
