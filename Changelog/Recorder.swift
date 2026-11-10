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
  private var metering: Task<Void, Never>?

  /// The microphone's loudness lately, oldest first, each 0 (silence) to
  /// 1, one every `meterInterval`: what the waveform under the clock draws,
  /// so a voice can see it's being heard.
  private(set) var levels: [Double] = []
  nonisolated static let meterInterval: Duration = .milliseconds(50)
  nonisolated static let levelsKept = 120

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
    meter(recorder)
  }

  /// Reads the recorder's level every `meterInterval` until it stops.
  private func meter(_ recorder: AVAudioRecorder) {
    recorder.isMeteringEnabled = true
    metering = Task { [weak self] in
      while !Task.isCancelled {
        recorder.updateMeters()
        self?.keep(Self.level(decibels: recorder.averagePower(forChannel: 0)))
        try? await Task.sleep(for: Self.meterInterval)
      }
    }
  }

  private func keep(_ level: Double) {
    levels.append(level)
    if levels.count > Self.levelsKept { levels.removeFirst(levels.count - Self.levelsKept) }
  }

  /// A meter's decibels (-160 to 0) as 0 to 1. A quiet room sits near
  /// -50 dB and speech near -20, so the 50 dB below full scale make the
  /// span, and the square root lifts a soft voice off the floor.
  nonisolated static func level(decibels: Float) -> Double {
    let floor: Float = -50
    guard decibels.isFinite, decibels > floor else { return 0 }
    return Double(min(1, (decibels - floor) / -floor)).squareRoot()
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
    metering?.cancel()
    metering = nil
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
