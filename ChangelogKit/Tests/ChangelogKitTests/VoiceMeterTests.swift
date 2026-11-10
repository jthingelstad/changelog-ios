import Testing
@testable import ChangelogKit

@Suite struct VoiceMeterTests {
  /// A room humming along at its own level, a decibel or two either way.
  private func room(_ meter: inout VoiceMeter, at level: Float = -42, readings: Int = 40) -> [Double] {
    (0..<readings).map { meter.level(decibels: level + Float($0 % 5) - 2) }
  }

  @Test func aRoomAloneDrawsNothing() {
    var meter = VoiceMeter()
    #expect(room(&meter).allSatisfy { $0 == 0 })
  }

  @Test func aVoiceStandsOutOfTheRoom() {
    var meter = VoiceMeter()
    _ = room(&meter)
    let spoken = meter.level(decibels: -18)
    #expect(spoken > 0.6)
    #expect(meter.level(decibels: -32) > 0)
    #expect(meter.level(decibels: -32) < spoken)
  }

  @Test func aLoudRoomIsStillJustTheRoom() {
    var meter = VoiceMeter()
    #expect(room(&meter, at: -25).allSatisfy { $0 == 0 })
  }

  @Test func theBackgroundCreepsUpAndDropsAtOnce() {
    var meter = VoiceMeter()
    _ = meter.level(decibels: -45)
    for _ in 0..<20 { _ = meter.level(decibels: -20) }
    let after = try! #require(meter.background)
    #expect(abs(after - (-45 + 20 * VoiceMeter.rise)) < 0.001)
    _ = meter.level(decibels: -50)
    #expect(meter.background == -50)
  }

  @Test func aSteadyNewNoiseFlattensOut() {
    var meter = VoiceMeter()
    _ = room(&meter, at: -45)
    let readings = (0..<400).map { _ in meter.level(decibels: -20) }
    #expect(readings.first! > 0.6)
    #expect(readings.last! == 0)
  }

  @Test func silenceIsNothing() {
    var meter = VoiceMeter()
    #expect(meter.level(decibels: -.infinity) == 0)
    #expect(meter.background == nil)
    #expect(meter.level(decibels: .nan) == 0)
  }
}
