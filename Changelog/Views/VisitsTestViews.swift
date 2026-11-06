import ChangelogKit
import CoreLocation
import MapKit
import SwiftUI

/// The file the visits test left on this phone, kept as it was: the owner's
/// to read, share and delete, in a file that stays out of backups and goes
/// when signing out. Nothing writes to it now, and nothing in it goes to
/// Release Notes. The map here is where the app's own map starts (phase 4 of
/// `docs/CHECK-INS.md` in the Release Notes repo).
enum VisitsTest {
  static let log = VisitLog(url: URL.applicationSupportDirectory
    .appending(path: "Visits", directoryHint: .isDirectory)
    .appending(path: "changelog-visits.jsonl"))

  static var hasFile: Bool { FileManager.default.fileExists(atPath: log.url.path(percentEncoded: false)) }

  /// Signing out takes its record with it, as the test said it would.
  static func forget() { try? log.clear() }

  #if DEBUG
  /// A build this new never writes the file, so the test cycle makes one as
  /// the test did (`CHANGELOG_OLD_VISITS`, a debug build only).
  static func standIn() {
    guard ProcessInfo.processInfo.environment["CHANGELOG_OLD_VISITS"] != nil, !hasFile else { return }
    let arrival = Date.now.addingTimeInterval(-3600)
    try? log.append(VisitEvent(heard: .now, arrival: arrival, departure: .now.addingTimeInterval(-600), lat: 44.9778, lon: -93.2650,
                               accuracyM: 60, timeZone: TimeZone.current.identifier, appState: "background"))
  }
  #endif
}

/// What the test has found: the measures it is for, the stays on a map with
/// how sure iOS was of each, and the file to share.
struct VisitsTestPage: View {
  @State private var events = VisitsTest.log.read()
  @State private var problem: String?
  @State private var confirmDelete = false

  var body: some View {
    let stays = VisitStay.from(events)
    List {
      Group {
        if let problem {
          Text(problem).face(.hint).foregroundStyle(Color.tangerineInk)
        }
        if stays.isEmpty {
          Text("Nothing here. The test's stops have been deleted.")
            .face(.hint)
            .foregroundStyle(Color.ink2)
        } else {
          summary(VisitSummary(stays))
          Map {
            ForEach(stays) { stay in
              let center = CLLocationCoordinate2D(latitude: stay.lat, longitude: stay.lon)
              MapCircle(center: center, radius: stay.accuracyM)
                .foregroundStyle(Color.cobalt.opacity(0.18))
              Marker(stay.arrived.map(Self.time) ?? "Stop", coordinate: center)
                .tint(Color.cobalt)
            }
          }
          .frame(height: 280)
          .accessibilityLabel("Map of the visits from the test")
          ForEach(stays) { stay in VisitStayRow(stay: stay) }
          ShareLink("Share the file", item: VisitsTest.log.url, preview: SharePreview("Changelog visits"))
            .buttonStyle(QuietButtonStyle())
          Button("Delete them all", role: .destructive) { confirmDelete = true }
            .buttonStyle(QuietButtonStyle())
        }
        Color.clear.frame(height: 24)
      }
      .paperRow(top: 8, bottom: 8)
      .listRowSeparator(.hidden)
    }
    .paperList()
    .navigationTitle("Visits from the test")
    .navigationBarTitleDisplayMode(.inline)
    // Settings hides its bar; this screen needs Back.
    .toolbar(.visible, for: .navigationBar)
    .confirmationDialog("Delete every visit from the test?", isPresented: $confirmDelete, titleVisibility: .visible) {
      Button("Delete", role: .destructive) {
        do {
          try VisitsTest.log.clear()
          events = []
          problem = nil
        } catch {
          problem = "Couldn't delete them: \(error.localizedDescription)"
        }
      }
    }
  }

  private func summary(_ summary: VisitSummary) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("\(Self.count(summary.stays, "stop")) over \(Self.count(summary.days, "day"))").face(.line).foregroundStyle(Color.ink)
      ForEach(Self.lines(summary), id: \.self) { line in
        Text(line).face(.meta).foregroundStyle(Color.ink3)
      }
    }
    .accessibilityElement(children: .combine)
  }

  private static func lines(_ summary: VisitSummary) -> [String] {
    [
      summary.shortestMinutes.map { "Shortest stay: \($0) min" },
      summary.medianMinutes.map { "Typical stay: \($0) min" },
      summary.medianAccuracyM.map { "Typical accuracy: \($0) m" },
      summary.medianMinutesToHearArrival.map { "Heard \($0) min after arriving, typically" },
      summary.medianMinutesToHearLeaving.map { "Heard \($0) min after leaving, typically" },
    ].compactMap { $0 }
  }

  private static func count(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }

  static func time(_ date: Date) -> String {
    date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
  }
}

private struct VisitStayRow: View {
  let stay: VisitStay

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(when).face(.line).foregroundStyle(Color.ink)
      Text(heard).face(.meta).foregroundStyle(Color.ink3)
    }
    .accessibilityElement(children: .combine)
  }

  private var when: String {
    let arrived = stay.arrived.map(VisitsTestPage.time) ?? "Arrival unknown"
    guard let left = stay.left else { return "\(arrived), still there" }
    let time = left.formatted(.dateTime.hour().minute())
    return stay.minutes.map { "\(arrived) to \(time), \($0) min" } ?? "\(arrived) to \(time)"
  }

  private var heard: String {
    var parts = ["within \(Int(stay.accuracyM.rounded())) m"]
    if let arriving = stay.minutesToHearArrival { parts.append("heard \(arriving) min after arriving") }
    if let leaving = stay.minutesToHearLeaving { parts.append("heard \(leaving) min after leaving") }
    return parts.joined(separator: " · ")
  }
}
