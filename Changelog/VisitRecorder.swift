import ChangelogKit
import CoreLocation
import UIKit

/// The test of iOS's Visits service for Breakpoints: while its switch is on,
/// every visit iOS reports goes in a file on this phone, and nowhere else.
/// iOS can start the app in the background to deliver one, so this is made as
/// the app starts, with its delegate set, before anything else can miss it.
@MainActor @Observable
final class VisitRecorder: NSObject, CLLocationManagerDelegate {
  static let shared = VisitRecorder()

  private let manager = CLLocationManager()
  private let defaults = UserDefaults.standard
  private let log: VisitLog
  private(set) var events: [VisitEvent]
  private(set) var status: CLAuthorizationStatus
  private(set) var reduced: Bool
  private(set) var problem: String?
  private(set) var on: Bool

  var url: URL { log.url }

  override init() {
    let support = URL.applicationSupportDirectory.appending(path: "Visits", directoryHint: .isDirectory)
    log = VisitLog(url: support.appending(path: "changelog-visits.jsonl"))
    events = log.read()
    status = manager.authorizationStatus
    reduced = manager.accuracyAuthorization == .reducedAccuracy
    on = defaults.bool(forKey: "visits.on")
    super.init()
    manager.delegate = self
    if on { manager.startMonitoringVisits() }
  }

  /// Asks for Always, which iOS only ever asks once; after that it is the
  /// Settings app's to change.
  func set(on wanted: Bool) {
    on = wanted
    defaults.set(wanted, forKey: "visits.on")
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

  func clear() {
    do {
      try log.clear()
      events = []
      problem = nil
    } catch {
      problem = "Couldn't delete them: \(error.localizedDescription)"
    }
  }

  /// Signing out ends the test and takes its record with it.
  func forget() {
    set(on: false)
    clear()
  }

  nonisolated func locationManager(_ manager: CLLocationManager, didVisit visit: CLVisit) {
    let (arrival, departure) = (visit.arrivalDate, visit.departureDate)
    let (lat, lon, accuracy) = (visit.coordinate.latitude, visit.coordinate.longitude, visit.horizontalAccuracy)
    MainActor.assumeIsolated { record(arrival: arrival, departure: departure, lat: lat, lon: lon, accuracy: accuracy) }
  }

  nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    let status = manager.authorizationStatus
    let reduced = manager.accuracyAuthorization == .reducedAccuracy
    MainActor.assumeIsolated {
      self.status = status
      self.reduced = reduced
    }
  }

  private func record(arrival: Date, departure: Date, lat: Double, lon: Double, accuracy: Double) {
    let state = UIApplication.shared.applicationState == .active ? "active" : "background"
    let event = VisitEvent(heard: .now, arrival: arrival, departure: departure, lat: lat, lon: lon, accuracyM: accuracy,
                           timeZone: TimeZone.current.identifier, appState: state)
    do {
      try log.append(event)
      events.append(event)
      problem = nil
    } catch {
      problem = "Couldn't keep a visit: \(error.localizedDescription)"
    }
  }

  #if DEBUG
  /// A simulator never reports a visit, so the test cycle stands in for iOS
  /// (`CHANGELOG_VISIT`, a debug build only): an arrival, then its leaving.
  private func standIn() {
    guard ProcessInfo.processInfo.environment["CHANGELOG_VISIT"] != nil else { return }
    let arrival = Date.now.addingTimeInterval(-3600)
    record(arrival: arrival, departure: .distantFuture, lat: 44.9778, lon: -93.2650, accuracy: 120)
    record(arrival: arrival, departure: .now.addingTimeInterval(-600), lat: 44.9778, lon: -93.2650, accuracy: 60)
  }
  #endif
}
