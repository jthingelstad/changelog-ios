import ChangelogKit
import MapKit
import SwiftUI

struct CheckInMapRoute: Hashable {}

/// Everywhere you've stopped: a pin for each place, opening its stops. Check-ins
/// only, read whole as the web's Map is, and held in memory. It opens with reading
/// locked, as a check-in's page does (Jamie's call 4, in the design).
struct CheckInMapView: View {
  @Environment(AppModel.self) private var model
  @State private var stays: [CheckIn] = []
  @State private var camera: MapCameraPosition = .automatic
  @State private var chosen: String?
  @State private var loading = true
  @State private var problem: String?

  var body: some View {
    let pins = CheckInMap.pins(stays)
    Map(position: $camera, selection: $chosen) {
      ForEach(pins) { pin in
        Marker(pin.label, systemImage: "mappin", coordinate: CLLocationCoordinate2D(latitude: pin.lat, longitude: pin.lon))
          .tint(Color.cobalt)
          .tag(pin.id)
      }
    }
    .accessibilityLabel("Map of your check-ins")
    .overlay(alignment: .top) { status(pins) }
    .navigationTitle("Check-ins")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar(.visible, for: .navigationBar)
    .task(id: model.checkInChanges) { await load() }
    .sheet(item: Binding(get: { pins.first { $0.id == chosen } }, set: { chosen = $0?.id })) { pin in
      CheckInPinSheet(pin: pin)
    }
    // Write about this opens Log, which a sheet would stay on top of.
    .onChange(of: AppRoute.shared.newNotes) { chosen = nil }
  }

  @ViewBuilder private func status(_ pins: [CheckInPin]) -> some View {
    Group {
      if let problem {
        VStack(spacing: 4) {
          Text(problem).face(.hint).foregroundStyle(Color.tangerineInk)
          Button("Try again") { Task { await load() } }
            .buttonStyle(QuietButtonStyle())
        }
      } else if loading, pins.isEmpty {
        ProgressView().accessibilityLabel("Reading your check-ins")
      } else if pins.isEmpty {
        Text("No check-ins yet.").face(.hint).foregroundStyle(Color.ink2)
      }
    }
    .padding(.horizontal, 16).padding(.vertical, 10)
    .background(Color.paper.opacity(problem != nil || pins.isEmpty ? 1 : 0), in: .rect(cornerRadius: 8))
    .padding(.top, 12)
  }

  /// Every page, in turn. The first read fills in as it goes; a later one, after
  /// a name or a delete, takes the old pins away only once it has them all.
  private func load() async {
    loading = true
    problem = nil
    defer { loading = false }
    var read: [CheckIn] = []
    var before: String?
    do {
      repeat {
        let page = try await model.checkInPage(before: before)
        guard !Task.isCancelled else { return }
        read += page.items
        if read.count > stays.count { stays = read }
        before = page.next
      } while before != nil
      stays = read
    } catch {
      problem = error.message
    }
  }
}

/// A place's stops, newest first, each opening its page.
private struct CheckInPinSheet: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  let pin: CheckInPin
  @State private var path = NavigationPath()
  @State private var detent = PresentationDetent.medium

  var body: some View {
    NavigationStack(path: $path) {
      List {
        Group {
          ForEach(pin.stays) { stay in
            NavigationLink(value: ActivityStop(day: stay.day, id: stay.id)) {
              Text(line(stay)).face(.hint).foregroundStyle(Color.ink)
            }
          }
        }
        .paperRow(top: 8, bottom: 8)
      }
      .paperList()
      .navigationTitle(pin.label)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
      }
      .navigationDestination(for: ActivityStop.self) { CheckInPage(day: $0.day, id: $0.id) }
    }
    // A stop's page is longer than half a screen: Write about this is below its map.
    .presentationDetents([.medium, .large], selection: $detent)
    .onChange(of: path.isEmpty) { _, empty in
      if !empty { detent = .large }
    }
  }

  private func line(_ stay: CheckIn) -> String {
    let zone = stay.timeZone.flatMap(TimeZone.init(identifier:)) ?? .current
    let date = Day.label(stay.day, today: model.me?.today ?? stay.day)
    let times = CheckInWords.stay(arrived: stay.arrived, left: stay.left, source: stay.source, timeZone: zone)
    return times.map { "\(date), \($0)" } ?? date
  }
}
