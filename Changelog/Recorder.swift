import AVFoundation
import ChangelogKit
import Observation

/// A voice memo: AAC in an .m4a, mono, which Release Notes keeps as
/// `audio/mp4`. At 64 kbit/s the 50 MB a file may be is over an hour and
/// a half, so recording stops itself before then.
///
/// The microphone's own samples go two ways, as the web's recorder does:
/// into the file, and into the levels the waveform draws. AVAudioRecorder's
/// meter smooths its average over a long window, so its bars trailed a
/// voice; these are each 50 ms of sound as it was. The microphone comes
/// through Apple's voice processing where it answers, as a browser's does
/// through its noise suppression: a room's hum is taken out of the bars and
/// the memo alike.
@MainActor @Observable
final class Recorder {
  enum State: Equatable { case idle, recording, denied, failed }

  private(set) var state: State = .idle
  private var capture: Capture?
  private var starting = false
  private var stopped = false
  /// Levels heard but not yet drawn, and the beat that draws them.
  private var pending: [Double] = []
  private var pacing: Task<Void, Never>?

  /// The microphone's loudness lately, oldest first, each 0 (silence) to 1
  /// (`VoiceLevel`), one for every `meterInterval` of sound: what the
  /// waveform under the clock draws, so a voice can see it's being heard.
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
    pacing = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(Self.meterInterval))
        self?.draw()
      }
    }
  }

  /// iOS hands the tap its sound some 100 ms at a time, so levels come two
  /// or more together; drawn as they came, the bars lurched. They wait
  /// here and go on the waveform one a beat.
  private func keep(_ new: [Double]) {
    guard capture != nil else { return }
    pending.append(contentsOf: new)
  }

  private func draw() {
    guard !pending.isEmpty else { return }
    // Fallen behind (a slow beat adds up): catch up at once, so the bars
    // never trail the voice.
    let take = pending.count > 4 ? pending.count - 1 : 1
    levels.append(contentsOf: pending.prefix(take))
    pending.removeFirst(take)
    if levels.count > Self.levelsKept { levels.removeFirst(levels.count - Self.levelsKept) }
  }

  /// Wakes the audio session and starts the microphone off the main
  /// thread: it can take a while (a headset joining, say), and the screen
  /// mustn't freeze for it.
  @concurrent private nonisolated static func record(to url: URL, heard: @escaping @Sendable ([Double]) -> Void) async -> Capture? {
    do {
      let session = AVAudioSession.sharedInstance()
      // Voice processing is a play-and-record unit, so the session is one
      // too; nothing plays.
      try session.setCategory(.playAndRecord, mode: .default)
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
    pacing?.cancel()
    pacing = nil
    pending = []
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
///
/// It starts with Apple's voice processing and, if no sound comes through
/// that in a moment, starts again without it: build 102 turned it on and
/// the microphone sent nothing at all on Jamie's phone (2026-11-10), so a
/// memo must never hang on it again.
private final class Capture: @unchecked Sendable {
  let url: URL
  private let heard: @Sendable ([Double]) -> Void
  private var engine = AVAudioEngine()
  private let lock = NSLock()
  private var file: AVAudioFile?
  private var frames: AVAudioFramePosition = 0
  private var rate: Double = 0
  /// Signalled by every buffer the tap is given.
  private let first = DispatchSemaphore(value: 0)
  private let stopping = NSLock()
  private var ended = false

  /// How long voice processing has to send its first sound.
  static let patience: DispatchTimeInterval = .milliseconds(1500)

  init(url: URL, heard: @escaping @Sendable ([Double]) -> Void) throws {
    self.url = url
    self.heard = heard
    if (try? run(voiceProcessing: true)) != nil, first.wait(timeout: .now() + Self.patience) == .success {
      return
    }
    halt()
    engine = AVAudioEngine()
    try run(voiceProcessing: false)
  }

  private func run(voiceProcessing: Bool) throws {
    let input = engine.inputNode
    if voiceProcessing {
      // Apple's voice processing: noise suppression and gain control, as on
      // a call. It is one unit for the input and the output, and it sends
      // the input only while the output pulls it, so the input goes to the
      // main mixer, turned all the way down: nothing plays.
      try input.setVoiceProcessingEnabled(true)
    }
    let format = input.outputFormat(forBus: 0)
    guard format.sampleRate > 0, format.channelCount > 0,
      format.commonFormat == .pcmFormatFloat32
    else { throw CocoaError(.featureUnsupported) }
    if voiceProcessing {
      engine.connect(input, to: engine.mainMixerNode, format: format)
      engine.mainMixerNode.outputVolume = 0
    }
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
    lock.lock()
    rate = format.sampleRate
    frames = 0
    self.file = file
    lock.unlock()
    let mono = file.processingFormat
    let rate = format.sampleRate
    let limit = AVAudioFramePosition(Recorder.longest * rate)
    let chunk = max(1, Int(rate * Recorder.meterInterval))
    let heard = self.heard

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
        new.append(VoiceLevel.level(decibels: 20 * log10(rms)))
        at = end
      }

      self.lock.lock()
      guard let file = self.file, self.frames < limit else {
        self.lock.unlock()
        return
      }
      try? file.write(from: out)
      self.frames += AVAudioFramePosition(count)
      let full = self.frames >= limit
      self.lock.unlock()
      self.first.signal()
      heard(new)
      // At the longest a memo may be, the microphone goes off, as
      // AVAudioRecorder's did, so no bars move for sound Add won't keep.
      // An engine mustn't be stopped from its own tap, so another thread
      // does it.
      if full { DispatchQueue.global().async { self.stop() } }
    }
    engine.prepare()
    do {
      try engine.start()
    } catch {
      input.removeTap(onBus: 0)
      throw error
    }
  }

  /// Takes the engine down and empties the file, for another start.
  private func halt() {
    engine.inputNode.removeTap(onBus: 0)
    engine.stop()
    try? engine.inputNode.setVoiceProcessingEnabled(false)
    lock.lock()
    file?.close()
    file = nil
    frames = 0
    lock.unlock()
  }

  var elapsed: TimeInterval {
    lock.lock()
    defer { lock.unlock() }
    guard rate > 0 else { return 0 }
    return min(Double(frames) / rate, Recorder.longest)
  }

  /// Whether any sound reached the file.
  var wrote: Bool {
    lock.lock()
    defer { lock.unlock() }
    return frames > 0
  }

  /// Stops the microphone and closes the file, so it's whole on disk.
  /// Twice is once: the limit and Add or Cancel may both ask.
  func stop() {
    stopping.lock()
    defer { stopping.unlock() }
    guard !ended else { return }
    ended = true
    engine.inputNode.removeTap(onBus: 0)
    engine.stop()
    lock.lock()
    file?.close()
    file = nil
    lock.unlock()
  }
}
