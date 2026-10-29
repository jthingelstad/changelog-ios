import Foundation

public extension APIClient {
  /// A signed form for one file. Needs `media:write`. It has no receipt: a
  /// retry gets a new form, and an unused one expires.
  func startUpload(_ start: UploadStart) async throws(APIError) -> UploadForm {
    try await send("POST", "v1/uploads", body: start, expect: 201)
  }

  /// Posts a file to its signed form. The form goes to file storage, not to
  /// Release Notes, so it carries no token and no cookie.
  func post(_ file: Data, name: String, to form: UploadForm) async throws(APIError) {
    let boundary = "changelog-" + UUID().uuidString.lowercased()
    // S3's form is a full URL; the dev server's is a path on itself.
    var request = URLRequest(url: URL(string: form.url.relativeString, relativeTo: baseURL)?.absoluteURL ?? form.url)
    request.httpMethod = "POST"
    request.timeoutInterval = 300
    request.httpShouldHandleCookies = false
    request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
    request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    let body = Multipart.body(fields: form.fields, file: file, name: name, type: form.type, boundary: boundary)
    let answer: (Data, URLResponse)
    do { answer = try await session.upload(for: request, from: body) } catch { throw .network(error) }
    guard let http = answer.1 as? HTTPURLResponse else {
      throw APIError(status: 0, code: "unreadable", message: "No answer from file storage.")
    }
    guard (200..<300).contains(http.statusCode) else {
      // A storage refusal (the form expired, the size was wrong) is worth
      // one more try with a new form; its body is storage's, never shown.
      throw APIError(status: http.statusCode >= 500 ? http.statusCode : 0, code: "upload_failed",
                     message: "A file didn't upload. It will be tried again.")
    }
  }

  /// Adds uploads to a note this token wrote.
  func addFiles(date: String, id: String, uploads: [UploadRef], idempotencyKey: String) async throws(APIError) -> NoteReceipt {
    struct Body: Encodable { var uploads: [UploadRef] }
    return try await send("POST", "v1/notes/\(date)/\(id)/media", body: Body(uploads: uploads), idempotencyKey: idempotencyKey)
  }

  /// Names the spot the phone is at, with the businesses nearby. Nothing is
  /// kept until a note takes the place.
  func here(_ spot: Spot) async throws(APIError) -> Here {
    try await send("POST", "v1/places/here", body: spot)
  }
}
