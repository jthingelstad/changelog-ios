import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Files and places on a note (`docs/API.md`, phase 3): photos, recordings
/// and PDFs go up through a signed form, and a note names them; a place is
/// the spot the phone is at, named by `POST /v1/places/here`.

/// `POST /v1/uploads`: a form for one file of an exact size.
public struct UploadStart: Codable, Sendable, Equatable {
  public var name: String?
  public var type: String
  public var size: Int
}

/// The signed form. Post `fields` and then the file, as `file`, to `url`
/// within `expiresIn` seconds; the token never goes with it.
public struct UploadForm: Codable, Sendable, Equatable {
  public var upload: String
  public var type: String
  public var url: URL
  public var fields: [String: String]
  public var expiresIn: Int
}

/// A file posted to its form, as a note's `uploads` names it.
public struct UploadRef: Codable, Sendable, Equatable {
  public var upload: String
  public var type: String
  public var name: String?

  public init(upload: String, type: String, name: String? = nil) {
    self.upload = upload
    self.type = type
    self.name = name
  }
}

/// Where the phone is, for `POST /v1/places/here`.
public struct Spot: Codable, Sendable, Equatable {
  public var lat: Double
  public var lon: Double
  public var accuracyM: Double?

  public init(lat: Double, lon: Double, accuracyM: Double? = nil) {
    self.lat = lat
    self.lon = lon
    self.accuracyM = accuracyM
  }
}

/// A spot with its names, sent back as a note's `place` as it came, with
/// `venue` set only when the owner picked a business nearby.
public struct DevicePlace: Codable, Sendable, Equatable {
  public var name: String
  public var region: String?
  public var country: String?
  public var tz: String?
  public var district: String?
  public var venue: String?
  public var lat: Double
  public var lon: Double
  public var accuracyM: Double?
  public var from: String

  /// What the note will be named by: the business picked, else the
  /// neighbourhood, else the city.
  public var label: String { venue ?? district ?? name }
}

/// `POST /v1/places/here`: the spot's names and up to 6 businesses within
/// the accuracy. Nothing is picked for the owner.
public struct Here: Codable, Sendable, Equatable {
  public var place: DevicePlace
  public var nearby: [Nearby]
}

public struct Nearby: Codable, Sendable, Equatable, Hashable {
  public var name: String
  public var lat: Double
  public var lon: Double
  public var distanceM: Double
}

/// A file waiting on this phone for its note. The bytes live in the
/// Outbox's files folder under `id`; `upload` is set once they're posted, so
/// a resend names the same upload under the same idempotency key.
public struct QueuedFile: Codable, Sendable, Equatable, Identifiable {
  public var id: UUID
  public var type: String
  public var name: String
  public var size: Int
  public var upload: String?

  public init(id: UUID = UUID(), type: String, name: String, size: Int, upload: String? = nil) {
    self.id = id
    self.type = type
    self.name = name
    self.size = size
    self.upload = upload
  }

  public var fileName: String { id.uuidString.lowercased() + "." + MediaType.fileExtension(type) }
  public var isPhoto: Bool { type.hasPrefix("image/") }
  public var isRecording: Bool { type.hasPrefix("audio/") }
}

/// What Release Notes keeps on a note: photos, recordings and PDFs, each at
/// most 50 MB, at most 20 a note.
public enum MediaType {
  public static let maxBytes = 50 * 1024 * 1024
  public static let maxFiles = 20

  /// The type the bytes say they are, from their first bytes, for the types
  /// Release Notes keeps; nil for anything else.
  public static func sniff(_ data: Data) -> String? {
    let b = [UInt8](data.prefix(16))
    func ascii(_ range: Range<Int>) -> String? {
      guard b.count >= range.upperBound else { return nil }
      return String(bytes: b[range], encoding: .ascii)
    }
    if b.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
    if b.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
    if ascii(0..<4) == "GIF8" { return "image/gif" }
    if ascii(0..<4) == "RIFF", ascii(8..<12) == "WEBP" { return "image/webp" }
    if ascii(0..<4) == "%PDF" { return "application/pdf" }
    if ascii(4..<8) == "ftyp", let brand = ascii(8..<12) {
      switch brand {
      case "heic", "heix", "heim", "heis": return "image/heic"
      case "mif1", "msf1", "heif": return "image/heif"
      case "M4A ", "M4B ": return "audio/mp4"
      default: return nil
      }
    }
    return nil
  }

  public static func fileExtension(_ type: String) -> String {
    switch type {
    case "image/jpeg": "jpg"
    case "image/png": "png"
    case "image/gif": "gif"
    case "image/webp": "webp"
    case "image/heic": "heic"
    case "image/heif": "heif"
    case "audio/mp4": "m4a"
    case "audio/mpeg": "mp3"
    case "application/pdf": "pdf"
    default: "bin"
    }
  }

  /// A photo as Release Notes shows it best: JPEG, PNG, GIF and WebP as
  /// they are; anything else ImageIO reads (a HEIC, say, which would get no
  /// thumbnail and never show in the email) made a JPEG with its metadata,
  /// time and place included, kept. Nil when the bytes aren't an image.
  public static func photo(_ data: Data) -> (data: Data, type: String)? {
    if let type = sniff(data), ["image/jpeg", "image/png", "image/gif", "image/webp"].contains(type) {
      return (data, type)
    }
    guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else {
      return nil
    }
    let out = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else {
      return nil
    }
    let options = [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary
    CGImageDestinationAddImageFromSource(destination, source, 0, options)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return (out as Data, "image/jpeg")
  }

  /// A small picture of a photo for the composer, without decoding it whole.
  public static func thumbnail(_ data: Data, maxPixels: Int = 240) -> CGImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    let options = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: maxPixels,
    ] as CFDictionary
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options)
  }
}

/// A `multipart/form-data` body for an upload form: every field, then the
/// file last, as `file`, as S3's POST policy wants it.
public enum Multipart {
  public static func body(fields: [String: String], file: Data, name: String, type: String, boundary: String) -> Data {
    head(fields: fields, name: name, type: type, boundary: boundary) + file + tail(boundary: boundary)
  }

  /// The same body written to `body`, the file copied from disk a piece at
  /// a time, so a 50 MB file never sits in memory (a share extension has
  /// little).
  public static func write(fields: [String: String], file: URL, name: String, type: String, boundary: String,
                           to body: URL) throws {
    guard FileManager.default.createFile(atPath: body.path(), contents: nil) else { throw CocoaError(.fileWriteUnknown) }
    let out = try FileHandle(forWritingTo: body)
    defer { try? out.close() }
    let source = try FileHandle(forReadingFrom: file)
    defer { try? source.close() }
    try out.write(contentsOf: head(fields: fields, name: name, type: type, boundary: boundary))
    while let piece = try source.read(upToCount: 1 << 20), !piece.isEmpty {
      try out.write(contentsOf: piece)
    }
    try out.write(contentsOf: tail(boundary: boundary))
  }

  static func head(fields: [String: String], name: String, type: String, boundary: String) -> Data {
    var head = ""
    for key in fields.keys.sorted() {
      head += "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(escape(key))\"\r\n\r\n\(fields[key]!)\r\n"
    }
    head += "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(escape(name))\"\r\n"
    head += "Content-Type: \(type)\r\n\r\n"
    return Data(head.utf8)
  }

  static func tail(boundary: String) -> Data {
    Data("\r\n--\(boundary)--\r\n".utf8)
  }

  /// A quote or a line break would end the header early.
  static func escape(_ s: String) -> String {
    s.replacingOccurrences(of: "\"", with: "%22").replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
  }
}
