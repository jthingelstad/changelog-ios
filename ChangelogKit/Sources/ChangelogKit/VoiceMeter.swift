/// How loud a voice memo's microphone is above the room it's in, for the
/// waveform under the recorder's clock (Jamie, 2026-11-10: it sat "nearly
/// halfway full, even when there's no real audio going on. So it needs to be
/// more focused on the voice").
///
/// A fixed scale lights up for a fan or a fridge as readily as for speech.
/// So the meter keeps the room's background: the quietest it has heard
/// lately, which drops at once to a quieter reading and creeps up only
/// slowly, so the gaps between words keep finding it again. Only sound
/// clearly above it moves a bar. A browser's microphone does much the same
/// with its own noise suppression, which is why the web's bars never needed
/// this.
public struct VoiceMeter: Sendable {
  /// How far above the background a sound must be to show at all: the
  /// room's own flutter stays under it.
  public static let margin: Float = 6
  /// The decibels above the margin that fill a bar: speech sits some 20 to
  /// 30 dB over a quiet room.
  public static let span: Float = 30
  /// How far the background creeps up for each reading that's louder than
  /// it: at 20 readings a second, 2 dB a second, so a steady new noise (a
  /// fan going on) flattens out in seconds while a sentence barely moves it.
  public static let rise: Float = 0.1

  /// The room's level in decibels, nil until the first reading.
  public private(set) var background: Float?

  public init() {}

  /// One reading, in decibels below full scale, as 0 (no more than the room)
  /// to 1. The square root lifts a soft voice off the floor.
  public mutating func level(decibels: Float) -> Double {
    guard decibels.isFinite else { return 0 }
    let room = min(decibels, (background ?? decibels) + Self.rise)
    background = room
    let above = decibels - room - Self.margin
    guard above > 0 else { return 0 }
    return Double(min(1, above / Self.span)).squareRoot()
  }
}
