import ChangelogKit
import CoreLocation
import MapKit
import SwiftUI

/// The switch for the visits test, in Settings. Off until turned on.
struct VisitsTestSection: View {
  @Environment(\.openURL) private var openURL
  private let recorder = VisitRecorder.shared

  var body: some View {
    Section {
      Toggle("Record visits", isOn: Binding(get: { recorder.on }, set: { recorder.set(on: $0) }))
      if recorder.on, recorder.status != .authorizedAlways {
        Button("Set Location to Always") {
          if let settings = URL(string: UIApplication.openSettingsURLString) { openURL(settings) }
        }
      }
      if recorder.on || !recorder.events.isEmpty {
        NavigationLink("Visits recorded") { VisitsTestPage() }
      }
    } header: {
      SectionHead("Visits test")
    } footer: {
      SectionNote(note, problem: recorder.on && recorder.status != .authorizedAlways)
    }
  }

  private var note: String {
    guard recorder.on else {
      return "A test for Breakpoints: writes down where iOS says you stopped, in a file on this phone. Nothing goes to Release Notes."
    }
    if recorder.status != .authorizedAlways {
      return "Location isn't set to Always, so this can only record while Changelog is open."
    }
    if recorder.reduced { return "Precise Location is off for Changelog, so these will be rough." }
    return "Recording on this phone. Nothing goes to Release Notes."
  }
}

/// What the test has found: the measures it is for, the stays on a map with
/// how sure iOS was of each, and the file to share.
struct VisitsTestPage: View {
  private let recorder = VisitRecorder.shared
  @State private var confirmDelete = false

  var body: some View {
    let stays = VisitStay.from(recorder.events)
    List {
      Group {
        if let problem = recorder.problem {
          Text(problem).face(.hint).foregroundStyle(Color.tangerineInk)
        }
        if stays.isEmpty {
          Text("Nothing yet. iOS reports a stop in its own time, often after you leave.")
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
          .accessibilityLabel("Map of the visits recorded")
          ForEach(stays) { stay in VisitStayRow(stay: stay) }
          ShareLink("Share the file", item: recorder.url, preview: SharePreview("Changelog visits"))
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
    .navigationTitle("Visits recorded")
    .navigationBarTitleDisplayMode(.inline)
    .confirmationDialog("Delete every visit recorded?", isPresented: $confirmDelete, titleVisibility: .visible) {
      Button("Delete", role: .destructive) { recorder.clear() }
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
