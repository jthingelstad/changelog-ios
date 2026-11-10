import Testing
@testable import ChangelogKit

@Suite struct VoiceLevelTests {
  /// The web's `level` gives the same for the same decibels.
  @Test(arguments: [
    (Float(-80), Double(0)),
    (-50, 0.0),
    (-25, Double(0.5).squareRoot()),
    (-12.5, Double(0.75).squareRoot()),
    (0, 1.0),
    (6, 1.0),
  ] as [(Float, Double)])
  func onTheWebsScale(decibels: Float, level: Double) {
    #expect(abs(VoiceLevel.level(decibels: decibels) - level) < 0.000_001)
  }

  @Test func silenceIsNothing() {
    #expect(VoiceLevel.level(decibels: -.infinity) == 0)
    #expect(VoiceLevel.level(decibels: .nan) == 0)
  }
}
