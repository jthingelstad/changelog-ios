import ChangelogKit
import MapKit
import SwiftUI

/// The map itself, as MapKit draws it in UIKit: SwiftUI's `Map` can't gather
/// marks as you zoom out, and an archive can hold thousands of notes with a
/// place. A check-in is a cobalt dot ringed in paper, notes a cobalt ring, as
/// the Android app draws them. Rings gather into a ring with a count, only
/// ever with rings; dots never gather or hide, so a stop and the notes
/// written there both show. Trails are lines in cobalt: solid joining the
/// check-ins, dotted joining the notes.
struct MapCanvas: UIViewRepresentable {
  var checkIns: [CheckInPin]
  var spots: [NoteSpot]
  var stayTrail: [MapPoint]
  var noteTrail: [MapPoint]
  /// The map moves to what shows when this changes.
  var frame: String
  var choose: @MainActor (MapChoice) -> Void

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeUIView(context: Context) -> MKMapView {
    let map = MKMapView()
    map.delegate = context.coordinator
    map.showsUserLocation = false
    map.register(StayDot.self, forAnnotationViewWithReuseIdentifier: StayDot.reuse)
    map.register(NoteRing.self, forAnnotationViewWithReuseIdentifier: NoteRing.reuse)
    map.register(NoteRings.self, forAnnotationViewWithReuseIdentifier: NoteRings.reuse)
    // The lines' colour is set as each is drawn: draw them again in the other appearance.
    let coordinator = context.coordinator
    map.registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (map: MKMapView, _: UITraitCollection) in
      coordinator.redrawTrails(on: map)
    }
    return map
  }

  func updateUIView(_ map: MKMapView, context: Context) {
    context.coordinator.show(self, on: map)
  }

  @MainActor final class Coordinator: NSObject, MKMapViewDelegate {
    private var choose: @MainActor (MapChoice) -> Void = { _ in }
    private var stays: [String: StayMark] = [:]
    private var notes: [String: NoteMark] = [:]
    private var trails: (stays: [MapPoint], notes: [MapPoint]) = ([], [])
    private var lines: [MKPolyline] = []
    private var framed: String?

    func show(_ canvas: MapCanvas, on map: MKMapView) {
      choose = canvas.choose
      var gone: [any MKAnnotation] = []
      var added: [any MKAnnotation] = []
      var nextStays: [String: StayMark] = [:]
      for pin in canvas.checkIns {
        if let mark = stays[pin.id], mark.pin == pin {
          nextStays[pin.id] = mark
        } else {
          let mark = StayMark(pin)
          nextStays[pin.id] = mark
          added.append(mark)
        }
      }
      gone += stays.filter { nextStays[$0.key] !== $0.value }.map(\.value)
      stays = nextStays
      var nextNotes: [String: NoteMark] = [:]
      for spot in canvas.spots {
        if let mark = notes[spot.id], mark.spot == spot {
          nextNotes[spot.id] = mark
        } else {
          let mark = NoteMark(spot)
          nextNotes[spot.id] = mark
          added.append(mark)
        }
      }
      gone += notes.filter { nextNotes[$0.key] !== $0.value }.map(\.value)
      notes = nextNotes
      map.removeAnnotations(gone)
      map.addAnnotations(added)

      if canvas.stayTrail != trails.stays || canvas.noteTrail != trails.notes {
        trails = (canvas.stayTrail, canvas.noteTrail)
        redrawTrails(on: map)
      }
      if canvas.frame != framed {
        let first = framed == nil
        framed = canvas.frame
        frame(map, animated: !first)
      }
    }

    func redrawTrails(on map: MKMapView) {
      map.removeOverlays(lines)
      lines = [line(trails.stays, kind: StayMark.kind), line(trails.notes, kind: NoteMark.kind)].compactMap(\.self)
      map.addOverlays(lines, level: .aboveRoads)
    }

    private func line(_ points: [MapPoint], kind: String) -> MKPolyline? {
      guard points.count > 1 else { return nil }
      let coordinates = points.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
      let line = MKPolyline(coordinates: coordinates, count: coordinates.count)
      line.title = kind
      return line
    }

    /// Everything that shows, with room around it; one spot alone, close in.
    private func frame(_ map: MKMapView, animated: Bool) {
      let spots = stays.values.map(\.coordinate) + notes.values.map(\.coordinate)
      guard let first = spots.first else { return }
      var rect = MKMapRect.null
      for spot in spots {
        let point = MKMapPoint(spot)
        rect = rect.union(MKMapRect(x: point.x, y: point.y, width: 1, height: 1))
      }
      let close = MKMapPointsPerMeterAtLatitude(first.latitude) * 800
      if rect.size.width < close, rect.size.height < close {
        let centre = MKMapPoint(x: rect.midX, y: rect.midY).coordinate
        map.setRegion(MKCoordinateRegion(center: centre, latitudinalMeters: 1600, longitudinalMeters: 1600), animated: animated)
      } else {
        map.setVisibleMapRect(rect, edgePadding: UIEdgeInsets(top: 48, left: 40, bottom: 56, right: 40), animated: animated)
      }
    }

    func mapView(_ map: MKMapView, viewFor annotation: any MKAnnotation) -> MKAnnotationView? {
      switch annotation {
      case is MKClusterAnnotation: map.dequeueReusableAnnotationView(withIdentifier: NoteRings.reuse, for: annotation)
      case is StayMark: map.dequeueReusableAnnotationView(withIdentifier: StayDot.reuse, for: annotation)
      case is NoteMark: map.dequeueReusableAnnotationView(withIdentifier: NoteRing.reuse, for: annotation)
      default: nil
      }
    }

    func mapView(_ map: MKMapView, didSelect annotation: any MKAnnotation) {
      map.deselectAnnotation(annotation, animated: false)
      switch annotation {
      case let rings as MKClusterAnnotation: map.showAnnotations(rings.memberAnnotations, animated: true)
      case let mark as StayMark: choose(.checkIn(mark.pin))
      case let mark as NoteMark: choose(.notes(mark.spot))
      default: break
      }
    }

    func mapView(_ map: MKMapView, rendererFor overlay: any MKOverlay) -> MKOverlayRenderer {
      guard let line = overlay as? MKPolyline else { return MKOverlayRenderer(overlay: overlay) }
      let drawn = MKPolylineRenderer(polyline: line)
      drawn.strokeColor = UIColor(Color.cobalt).resolvedColor(with: map.traitCollection).withAlphaComponent(0.8)
      drawn.lineCap = .round
      drawn.lineJoin = .round
      if line.title == NoteMark.kind {
        drawn.lineWidth = 4
        drawn.lineDashPattern = [0.1, 8]
      } else {
        drawn.lineWidth = 3
      }
      return drawn
    }
  }
}

/// A pin of check-ins: every stop at one place.
final class StayMark: NSObject, MKAnnotation {
  static let kind = "check-ins"
  let pin: CheckInPin
  let coordinate: CLLocationCoordinate2D
  let title: String?

  init(_ pin: CheckInPin) {
    self.pin = pin
    coordinate = CLLocationCoordinate2D(latitude: pin.lat, longitude: pin.lon)
    title = pin.label
  }
}

/// The notes at one spot. Its title is the place, never a note's words.
final class NoteMark: NSObject, MKAnnotation {
  static let kind = "notes"
  let spot: NoteSpot
  let coordinate: CLLocationCoordinate2D
  let title: String?

  init(_ spot: NoteSpot) {
    self.spot = spot
    coordinate = CLLocationCoordinate2D(latitude: spot.lat, longitude: spot.lon)
    title = spot.label
  }
}

/// A circle of one colour with a smaller one of another inside: a dot ringed
/// in paper, or a ring. Each is a view with the app's own colours, so both
/// follow the phone's appearance.
private final class Rings: UIView {
  private let inner = UIView()
  var width: CGFloat = 3 { didSet { setNeedsLayout() } }

  init(outer: Color, inner colour: Color) {
    super.init(frame: .zero)
    backgroundColor = UIColor(outer)
    inner.backgroundColor = UIColor(colour)
    addSubview(inner)
    isUserInteractionEnabled = false
  }

  required init?(coder: NSCoder) { nil }

  override func layoutSubviews() {
    super.layoutSubviews()
    layer.cornerRadius = bounds.width / 2
    inner.frame = bounds.insetBy(dx: width, dy: width)
    inner.layer.cornerRadius = inner.bounds.width / 2
  }
}

/// A check-in: a cobalt dot ringed in paper, over the notes. It never gathers
/// or hides, so a stop shows wherever notes are.
final class StayDot: MKAnnotationView {
  static let reuse = "stay"
  private let dot = Rings(outer: .paper, inner: .cobalt)

  override init(annotation: (any MKAnnotation)?, reuseIdentifier: String?) {
    super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
    frame = CGRect(x: 0, y: 0, width: 32, height: 32)
    dot.width = 2.5
    dot.frame = CGRect(x: 8, y: 8, width: 16, height: 16)
    addSubview(dot)
    collisionMode = .none
    displayPriority = .required
    zPriority = .max
    isAccessibilityElement = true
    accessibilityTraits = .button
  }

  required init?(coder: NSCoder) { nil }

  override func prepareForDisplay() {
    super.prepareForDisplay()
    guard let mark = annotation as? StayMark else { return }
    let stops = mark.pin.stays.count
    accessibilityLabel = "\(mark.pin.label), \(stops) \(stops == 1 ? "check-in" : "check-ins")"
  }
}

/// Notes at one spot: a cobalt ring, gathering with other rings as you zoom out.
final class NoteRing: MKAnnotationView {
  static let reuse = "ring"
  private let ring = Rings(outer: .cobalt, inner: .paper)

  override init(annotation: (any MKAnnotation)?, reuseIdentifier: String?) {
    super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
    frame = CGRect(x: 0, y: 0, width: 32, height: 32)
    ring.frame = CGRect(x: 8, y: 8, width: 16, height: 16)
    addSubview(ring)
    clusteringIdentifier = NoteMark.kind
    collisionMode = .circle
    displayPriority = .defaultHigh
    zPriority = .defaultUnselected
    isAccessibilityElement = true
    accessibilityTraits = .button
  }

  required init?(coder: NSCoder) { nil }

  override func prepareForDisplay() {
    super.prepareForDisplay()
    clusteringIdentifier = NoteMark.kind
    guard let mark = annotation as? NoteMark else { return }
    let count = mark.spot.notes.count
    accessibilityLabel = "\(count) \(count == 1 ? "note" : "notes") at \(mark.spot.label)"
  }
}

/// Rings gathered as you zoom out: a larger ring with how many notes, in
/// cobalt. Tapping it moves in to them.
final class NoteRings: MKAnnotationView {
  static let reuse = "rings"
  private let ring = Rings(outer: .cobalt, inner: .paper)
  private let count = UILabel()

  override init(annotation: (any MKAnnotation)?, reuseIdentifier: String?) {
    super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
    addSubview(ring)
    count.textColor = UIColor(Color.cobalt)
    count.textAlignment = .center
    count.font = .systemFont(ofSize: 13, weight: .bold)
    count.adjustsFontSizeToFitWidth = true
    count.minimumScaleFactor = 0.6
    addSubview(count)
    collisionMode = .circle
    displayPriority = .defaultHigh
    zPriority = .defaultUnselected
    isAccessibilityElement = true
    accessibilityTraits = .button
  }

  required init?(coder: NSCoder) { nil }

  override func prepareForDisplay() {
    super.prepareForDisplay()
    let notes = (annotation as? MKClusterAnnotation)?.memberAnnotations.reduce(0) { sum, member in
      sum + ((member as? NoteMark)?.spot.notes.count ?? 1)
    } ?? 0
    let side: CGFloat = notes < 10 ? 30 : notes < 100 ? 36 : 44
    frame = CGRect(x: 0, y: 0, width: side, height: side)
    ring.frame = bounds
    count.frame = bounds.insetBy(dx: 5, dy: 5)
    count.text = notes.formatted()
    accessibilityLabel = "\(notes.formatted()) notes nearby"
    accessibilityHint = "Moves in to them"
  }
}
