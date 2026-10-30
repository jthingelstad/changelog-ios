import ChangelogKit
import CoreLocation
import Synchronization

/// Where the phone is, once, when the owner asks for Here (or has "Add where
/// I am" on). Nothing runs in the background and nothing is kept: the spot
/// goes to Release Notes to be named, and only the place a note takes stays.
enum Locator {
  enum Fix: Equatable { case spot(Spot), denied, unavailable }

  /// The first fix good to 100 m, or the best one within `timeout` of the
  /// permission being settled: the time the owner spends on iOS's first
  /// "Allow While Using" alert doesn't count.
  @MainActor
  static func spot(within timeout: Duration = .seconds(8)) async -> Fix {
    // Asks for When In Use the first time; after that it only says so.
    let session = CLServiceSession(authorization: .whenInUse)
    defer { session.invalidate() }
    let best = Best()
    let (settled, settle) = AsyncStream<Never>.makeStream()
    if CLLocationManager().authorizationStatus != .notDetermined { settle.finish() }
    let reading = Task { () -> Fix? in
      defer { settle.finish() }
      do {
        for try await update in CLLocationUpdate.liveUpdates() {
          if update.authorizationDenied || update.authorizationDeniedGlobally || update.authorizationRestricted {
            return .denied
          }
          // The alert is still up: the time starts once it is answered.
          if update.authorizationRequestInProgress { continue }
          settle.finish()
          guard let location = update.location, location.horizontalAccuracy >= 0 else { continue }
          let spot = Spot(lat: location.coordinate.latitude, lon: location.coordinate.longitude,
                          accuracyM: location.horizontalAccuracy.rounded())
          if best.keep(spot) { return .spot(spot) }
        }
      } catch {}
      return nil
    }
    let timer = Task {
      for await _ in settled {}
      try? await Task.sleep(for: timeout)
      reading.cancel()
    }
    let answer = await reading.value
    timer.cancel()
    return answer ?? best.spot.map(Fix.spot) ?? .unavailable
  }

  /// The most accurate fix so far, for when time runs out first.
  private final class Best: Sendable {
    private let held = Mutex<Spot?>(nil)

    var spot: Spot? { held.withLock { $0 } }

    /// Keeps `spot` if it is the best yet; true once it is good enough.
    func keep(_ spot: Spot) -> Bool {
      held.withLock { held in
        if (spot.accuracyM ?? .infinity) < (held?.accuracyM ?? .infinity) { held = spot }
      }
      return (spot.accuracyM ?? .infinity) <= 100
    }
  }
}
