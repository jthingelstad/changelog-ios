/// How loud a voice memo's microphone is, for the waveform under the
/// recorder's clock: the web's scale (`web/src/components/recordwave.tsx`
/// in Release Notes) and Android's.
///
/// The microphone's sound comes through Apple's voice processing, which
/// takes out a room's hum and evens out a voice, as a browser's microphone
/// does with its noise suppression; so a fixed scale is enough, as it is on
/// the web (Jamie, 2026-11-10: "we should try whatever the default voice
/// mode is").
public enum VoiceLevel {
  /// Below this, in decibels under full scale, is nothing: a quiet room.
  public static let floor: Float = -50

  /// A reading in decibels as 0 (silence) to 1. Speech sits near -20 dB,
  /// and the square root lifts a soft voice off the floor.
  public static func level(decibels: Float) -> Double {
    guard decibels.isFinite, decibels > floor else { return 0 }
    return Double(min(1, (decibels - floor) / -floor)).squareRoot()
  }
}
