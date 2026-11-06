import ChangelogKit
import CoreLocation
import UIKit

/// Check-ins' switch and iOS's Visits service. While it is on, every stop iOS
/// reports goes to the Outbox under its own key, so a bad connection loses
/// nothing. iOS can start the app in the background to deliver one, so this is
/// made as the app starts, with its delegate set, before anything can miss it.
@MainActor @Observable
final class CheckInRecorder: NSObject, CLLocationManagerDelegate {
  static let shared = CheckInRecorder()
  static let onKey = "checkins.on"
  /// The visits test's switch, in builds before this one.
  private static let testKey = "visits.on"

  private let manager = CLLocationManager()
  private let defaults = UserDefaults.standard
  private(set) var status: CLAuthorizationStatus
  private(set) var reduced: Bool
  private(set) var on: Bool
  /// Takes a stop into the queue; false when it can't be kept yet (before the
  /// phone's first unlock, or no room). The app's model, set as it starts.
  @ObservationIgnored private var keep: (@MainActor (CheckInReport) async -> Bool)?
  /// Stops heard that the queue couldn't take yet, tried again with the next
  /// stop and when the app is opened.
  @ObservationIgnored private var unkept: [CheckInReport] = []
  @ObservationIgnored private var handing = false

  override init() {
    status = manager.authorizationStatus
    reduced = manager.accuracyAuthorization == .reducedAccuracy
    on = defaults.bool(forKey: Self.onKey)
    super.init()
    manager.delegate = self
    // The test promised nothing goes to Release Notes, so a phone that had it
    // on starts here with Check-ins off, and iOS stops delivering to it. Only
    // when its key is there, since before a phone's first unlock these
    // defaults read as empty and must not end monitoring.
    if defaults.object(forKey: Self.testKey) != nil {
      defaults.removeObject(forKey: Self.testKey)
      if !on { manager.stopMonitoringVisits() }
    }
    if on { manager.startMonitoringVisits() }
  }

  func attach(_ keep: @escaping @MainActor (CheckInReport) async -> Bool) {
    self.keep = keep
  }

  /// The app is on the screen: the switch and permission as they are now, and
  /// anything the queue couldn't take before.
  func refresh() {
    on = defaults.bool(forKey: Self.onKey)
    status = manager.authorizationStatus
    reduced = manager.accuracyAuthorization == .reducedAccuracy
    Task { await handOver() }
  }

  /// Asks for Always, which iOS only ever asks once; after that it is the
  /// Settings app's to change.
  func set(on wanted: Bool) {
    on = wanted
    defaults.set(wanted, forKey: Self.onKey)
    guard wanted else {
      manager.stopMonitoringVisits()
      return
    }
    if status == .notDetermined || status == .authorizedWhenInUse { manager.requestAlwaysAuthorization() }
    manager.startMonitoringVisits()
    #if DEBUG
    standIn()
    #endif
  }

  /// Signing out stops recording. The check-ins stay on the account.
  func forget() {
    unkept = []
    set(on: false)
  }

  nonisolated func locationManager(_ manager: CLLocationManager, didVisit visit: CLVisit) {
    let (arrival, departure) = (visit.arrivalDate, visit.departureDate)
    let (lat, lon, accuracy) = (visit.coordinate.latitude, visit.coordinate.longitude, visit.horizontalAccuracy)
    MainActor.assumeIsolated { heard(arrival: arrival, departure: departure, lat: lat, lon: lon, accuracy: accuracy) }
  }

  nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    let status = manager.authorizationStatus
    let reduced = manager.accuracyAuthorization == .reducedAccuracy
    MainActor.assumeIsolated {
      self.status = status
      self.reduced = reduced
    }
  }

  private func heard(arrival: Date, departure: Date, lat: Double, lon: Double, accuracy: Double) {
    // Read again: a launch before the phone's first unlock read no switch.
    on = defaults.bool(forKey: Self.onKey)
    guard on, let report = CheckInReport.visit(arrival: arrival, departure: departure, lat: lat, lon: lon, accuracy: accuracy) else { return }
    unkept.append(report)
    Task { await handOver() }
  }

  /// One at a time and in order, so an arrival is never sent after its leaving.
  private func handOver() async {
    guard !handing, let keep else { return }
    handing = true
    defer { handing = false }
    while let next = unkept.first {
      guard await keep(next) else { return }
      unkept.removeFirst()
    }
  }

  #if DEBUG
  /// A simulator never reports a visit, so the test cycle stands in for iOS
  /// (`CHANGELOG_VISIT`, a debug build only): an arrival, then its leaving.
  private func standIn() {
    guard ProcessInfo.processInfo.environment["CHANGELOG_VISIT"] != nil else { return }
    let arrival = Date.now.addingTimeInterval(-3600)
    heard(arrival: arrival, departure: .distantFuture, lat: 44.9778, lon: -93.2650, accuracy: 120)
    heard(arrival: arrival, departure: .now.addingTimeInterval(-600), lat: 44.9778, lon: -93.2650, accuracy: 60)
  }
  #endif
}
