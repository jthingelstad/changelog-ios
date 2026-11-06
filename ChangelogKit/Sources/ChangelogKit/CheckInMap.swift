import Foundation

/// One pin on the app's map: every stop at one place, newest first. A place
/// someone goes to each day would otherwise stack its pins on one spot.
public struct CheckInPin: Identifiable, Sendable, Equatable {
  public var stays: [CheckIn]

  public var id: String { stays[0].id }
  public var label: String { stays[0].label }
  public var lat: Double { stays[0].lat }
  public var lon: Double { stays[0].lon }
}

public enum CheckInMap {
  /// How near counts as the same place, as on the server
  /// (`SAME_PLACE_METRES` in Release Notes' `packages/domain/check-ins.ts`).
  static let samePlaceMetres = 100.0

  /// Stays as `/v1` lists them, newest first, gathered into pins. Stays share
  /// a pin at one remembered place, or under one name within 100 m. Two real
  /// shops next door keep their own, as two stops do in Activity.
  public static func pins(_ stays: [CheckIn]) -> [CheckInPin] {
    var pins: [CheckInPin] = []
    var remembered: [String: Int] = [:]
    for stay in stays {
      let found = stay.place.map { remembered[$0] } ?? pins.firstIndex { pin in
        pin.stays[0].place == nil && pin.label == stay.label && metres(pin.lat, pin.lon, stay.lat, stay.lon) <= samePlaceMetres
      }
      if let found {
        pins[found].stays.append(stay)
      } else {
        pins.append(CheckInPin(stays: [stay]))
        if let place = stay.place { remembered[place] = pins.count - 1 }
      }
    }
    return pins
  }

  /// Metres between two spots, along the ground, as the server works it out.
  static func metres(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
    let radians = Double.pi / 180
    let dLat = (lat2 - lat1) * radians, dLon = (lon2 - lon1) * radians
    let h = pow(sin(dLat / 2), 2) + cos(lat1 * radians) * cos(lat2 * radians) * pow(sin(dLon / 2), 2)
    return 2 * 6_371_000 * asin(min(1, h.squareRoot()))
  }
}
