import AVFoundation
import Observation

/// A voice memo: AAC in an .m4a, mono, which Release Notes keeps as
/// `audio/mp4`. At 64 kbit/s the 50 MB a file may be is over an hour and
/// a half, so recording stops itself before then.
///
/// The microphone's own samples go two ways, as the web's recorder does:
/// into the file, and into the levels the waveform draws. AVAudioRecorder's
/// meter smooths its average over a long window, so its bars trailed a
/// voice; these are each 50 ms of sound as it was.
@MainActor @Observable
final class Recorder {
  enum State: Equatable { case idle, recording, denied, failed }

  private(set) var state: State = .idle
  private var capture: Capture?
  private var starting = false
  private var stopped = false

  /// The microphone's loudness lately, oldest first, each 0 (silence) to
  /// 1, one for every `meterInterval` of sound: what the waveform under
  /// the clock draws, so a voice can see it's being heard.
  private(set) var levels: [Double] = []
  nonisolated static let meterInterval: TimeInterval = 0.05
  nonisolated static let levelsKept = 120

  nonisolated static let longest: TimeInterval = 100 * 60

  var elapsed: TimeInterval { capture?.elapsed ?? 0 }

  func start() async {
    guard state == .idle, !starting, !stopped else { return }
    starting = true
    defer { starting = false }
    guard await AVAudioApplication.requestRecordPermission() else {
      state = .denied
      return
    }
    let url = FileManager.default.temporaryDirectory.appending(path: "voice-\(UUID().uuidString.lowercased()).m4a")
    let heard: @Sendable ([Double]) -> Void = { [weak self] new in
      Task { @MainActor in self?.keep(new) }
    }
    guard let capture = await Self.record(to: url, heard: heard) else {
      try? FileManager.default.removeItem(at: url)
      state = .failed
      return
    }
    // Cancelled while it started: nothing keeps the microphone on.
    guard !stopped else {
      capture.stop()
      Self.deactivate()
      try? FileManager.default.removeItem(at: url)
      return
    }
    self.capture = capture
    state = .recording
  }

  private func keep(_ new: [Double]) {
    guard capture != nil else { return }
    levels.append(contentsOf: new)
    if levels.count > Self.levelsKept { levels.removeFirst(levels.count - Self.levelsKept) }
  }

  /// A level in decibels (-160 to 0) as 0 to 1. A quiet room sits near
  /// -50 dB and speech near -20, so the 50 dB below full scale make the
  /// span, and the square root lifts a soft voice off the floor. The web
  /// reads its level the same way.
  nonisolated static func level(decibels: Float) -> Double {
    let floor: Float = -50
    guard decibels.isFinite, decibels > floor else { return 0 }
    return Double(min(1, (decibels - floor) / -floor)).squareRoot()
  }

  /// Wakes the audio session and starts the microphone off the main
  /// thread: it can take a while (a headset joining, say), and the screen
  /// mustn't freeze for it.
  @concurrent private nonisolated static func record(to url: URL, heard: @escaping @Sendable ([Double]) -> Void) async -> Capture? {
    do {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.record, mode: .default)
      try session.setActive(true)
      return try Capture(url: url, heard: heard)
    } catch {
      return nil
    }
  }

  private nonisolated static func deactivate() {
    Task.detached { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
  }

  /// Stops and answers the recording's bytes; nil if there was none.
  func finish() -> Data? {
    guard let capture else { return nil }
    capture.stop()
    self.capture = nil
    state = .idle
    Self.deactivate()
    defer { try? FileManager.default.removeItem(at: capture.url) }
    return capture.wrote ? try? Data(contentsOf: capture.url) : nil
  }

  func cancel() {
    stopped = true
    _ = finish()
  }
}

/// The running microphone: an engine whose input tap writes each buffer to
/// the file and measures it. The tap runs on the engine's own thread, so
/// everything it touches is behind the lock.
private final class Capture: @unchecked Sendable {
  let url: URL
  private let engine = AVAudioEngine()
  private let lock = NSLock()
  private var file: AVAudioFile?
  private var frames: AVAudioFramePosition = 0
  private let rate: Double

  init(url: URL, heard: @escaping @Sendable ([Double]) -> Void) throws {
    self.url = url
    let input = engine.inputNode
    let format = input.outputFormat(forBus: 0)
    guard format.sampleRate > 0, format.channelCount > 0 else { throw CocoaError(.featureUnsupported) }
    rate = format.sampleRate
    let file = try AVAudioFile(
      forWriting: url,
      settings: [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: format.sampleRate,
        AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: 64_000,
      ],
      commonFormat: .pcmFormatFloat32,
      interleaved: false
    )
    self.file = file
    let mono = file.processingFormat
    let limit = AVAudioFramePosition(Recorder.longest * rate)
    let chunk = max(1, Int(rate * Recorder.meterInterval))

    input.installTap(onBus: 0, bufferSize: AVAudioFrameCount(chunk), format: format) { [weak self] buffer, _ in
      guard let self, let samples = buffer.floatChannelData?[0] else { return }
      let count = Int(buffer.frameLength)
      // The first channel alone: a voice memo is mono.
      guard count > 0, let out = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: AVAudioFrameCount(count)),
        let dest = out.floatChannelData?[0]
      else { return }
      dest.update(from: samples, count: count)
      out.frameLength = AVAudioFrameCount(count)

      var new: [Double] = []
      var at = 0
      while at < count {
        let end = min(count, at + chunk)
        var sum: Float = 0
        for i in at..<end { sum += samples[i] * samples[i] }
        let rms = (sum / Float(end - at)).squareRoot()
        new.append(Recorder.level(decibels: 20 * log10(rms)))
        at = end
      }

      self.lock.lock()
      if let file = self.file, self.frames < limit {
        try? file.write(from: out)
        self.frames += AVAudioFramePosition(count)
      }
      self.lock.unlock()
      heard(new)
    }
    engine.prepare()
    do {
      try engine.start()
    } catch {
      input.removeTap(onBus: 0)
      throw error
    }
  }

  var elapsed: TimeInterval {
    lock.lock()
    defer { lock.unlock() }
    return min(Double(frames) / rate, Recorder.longest)
  }

  /// Whether any sound reached the file.
  var wrote: Bool {
    lock.lock()
    defer { lock.unlock() }
    return frames > 0
  }

  /// Stops the microphone and closes the file, so it's whole on disk.
  func stop() {
    engine.inputNode.removeTap(onBus: 0)
    engine.stop()
    lock.lock()
    file?.close()
    file = nil
    lock.unlock()
  }
}
