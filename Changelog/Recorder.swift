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

  static let longest: TimeInterval = 100 * 60

  var elapsed: TimeInterval { recorder?.currentTime ?? 0 }

  func start() async {
    guard state != .recording else { return }
    guard await AVAudioApplication.requestRecordPermission() else {
      state = .denied
      return
    }
    let url = FileManager.default.temporaryDirectory.appending(path: "voice-\(UUID().uuidString.lowercased()).m4a")
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
      guard recorder.record(forDuration: Self.longest) else { throw CocoaError(.fileWriteUnknown) }
      self.recorder = recorder
      file = url
      state = .recording
    } catch {
      try? FileManager.default.removeItem(at: url)
      state = .failed
    }
  }

  /// Stops and answers the recording's bytes; nil if there was none.
  func finish() -> Data? {
    guard let recorder, let file else { return nil }
    recorder.stop()
    self.recorder = nil
    self.file = nil
    state = .idle
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    defer { try? FileManager.default.removeItem(at: file) }
    return try? Data(contentsOf: file)
  }

  func cancel() {
    _ = finish()
  }
}
