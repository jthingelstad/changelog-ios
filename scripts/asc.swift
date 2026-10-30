#!/usr/bin/env swift
// One call to the App Store Connect API, with the team's API key, for the
// steps to outside testers that Xcode doesn't take (docs/DISTRIBUTION.md):
//
//   scripts/asc.swift GET '/v1/apps?filter[bundleId]=com.yourversionnumber.changelog'
//   scripts/asc.swift PATCH /v1/betaAppReviewDetails/<id> body.json [--token-file <file>]
//
// The key's ids come from Config/AppStoreConnect.local, as scripts/
// testflight.sh reads them, and the key from ~/.appstoreconnect. The key is
// read here and never printed. With --token-file, each {{REVIEW_TOKEN}} in
// the body becomes that file's contents (the review account's token), and
// what comes back has every token and demo password blanked, so neither
// reaches a terminal or a log.

import CryptoKit
import Foundation

func fail(_ message: String) -> Never {
  FileHandle.standardError.write(Data((message + "\n").utf8))
  exit(1)
}

var args = Array(CommandLine.arguments.dropFirst())
var tokenFile: String?
if let i = args.firstIndex(of: "--token-file") {
  guard i + 1 < args.count else { fail("--token-file needs a file.") }
  tokenFile = args[i + 1]
  args.removeSubrange(i...(i + 1))
}
guard args.count == 2 || args.count == 3 else {
  fail("Usage: scripts/asc.swift METHOD PATH [body.json] [--token-file <file>]")
}
let method = args[0].uppercased()
let path = args[1]

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let local = (try? String(contentsOf: root.appending(path: "Config/AppStoreConnect.local"), encoding: .utf8)) ?? ""
func value(_ name: String) -> String? {
  local.split(separator: "\n").first { $0.hasPrefix(name + "=") }.map { String($0.dropFirst(name.count + 1)) }
}
guard let keyID = value("ASC_KEY_ID"), let issuer = value("ASC_ISSUER_ID") else {
  fail("Config/AppStoreConnect.local needs ASC_KEY_ID and ASC_ISSUER_ID.")
}
let keyFile = FileManager.default.homeDirectoryForCurrentUser
  .appending(path: ".appstoreconnect/private_keys/AuthKey_\(keyID).p8")
guard let pem = try? String(contentsOf: keyFile, encoding: .utf8),
      let key = try? P256.Signing.PrivateKey(pemRepresentation: pem)
else { fail("The API key isn't in ~/.appstoreconnect/private_keys, or can't be read.") }

func base64URL(_ data: Data) -> String {
  data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
    .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
}
func json(_ object: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) }

// Apple's limit for a token's life is 20 minutes.
let now = Int(Date().timeIntervalSince1970)
let signing = base64URL(json(["alg": "ES256", "kid": keyID, "typ": "JWT"])) + "."
  + base64URL(json(["iss": issuer, "iat": now, "exp": now + 1200, "aud": "appstoreconnect-v1"]))
guard let signature = try? key.signature(for: Data(signing.utf8)) else { fail("The key couldn't sign.") }
let jwt = signing + "." + base64URL(signature.rawRepresentation)

var body: Data?
if args.count == 3 {
  guard var text = try? String(contentsOfFile: args[2], encoding: .utf8) else { fail("\(args[2]) can't be read.") }
  if let tokenFile {
    guard let token = try? String(contentsOfFile: tokenFile, encoding: .utf8)
      .trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty
    else { fail("\(tokenFile) can't be read.") }
    text = text.replacingOccurrences(of: "{{REVIEW_TOKEN}}", with: token)
  }
  guard (try? JSONSerialization.jsonObject(with: Data(text.utf8))) != nil else { fail("\(args[2]) isn't JSON.") }
  body = Data(text.utf8)
}

guard let url = URL(string: "https://api.appstoreconnect.apple.com" + path) else { fail("\(path) isn't a path.") }
var request = URLRequest(url: url)
request.httpMethod = method
request.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
request.setValue("application/json", forHTTPHeaderField: "Accept")
if let body {
  request.httpBody = body
  request.setValue("application/json", forHTTPHeaderField: "Content-Type")
}

/// Blanks a demo password and anything shaped like a Release Notes token.
func blank(_ value: Any) -> Any {
  switch value {
  case let object as [String: Any]:
    return object.reduce(into: [String: Any]()) { out, pair in
      out[pair.key] = pair.key == "demoAccountPassword" && !(pair.value is NSNull) ? "(blanked)" : blank(pair.value)
    }
  case let array as [Any]: return array.map(blank)
  case let text as String:
    return text.replacingOccurrences(of: "rn_[A-Za-z0-9_-]{16,}", with: "rn_(blanked)", options: .regularExpression)
  default: return value
  }
}

let done = DispatchSemaphore(value: 0)
var status = 0
var answer = Data()
URLSession.shared.dataTask(with: request) { data, response, error in
  if let error { FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8)) }
  status = (response as? HTTPURLResponse)?.statusCode ?? 0
  answer = data ?? Data()
  done.signal()
}.resume()
done.wait()

print("HTTP \(status)")
if let object = try? JSONSerialization.jsonObject(with: answer),
   let pretty = try? JSONSerialization.data(withJSONObject: blank(object), options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
  print(String(decoding: pretty, as: UTF8.self))
} else if !answer.isEmpty {
  print("(\(answer.count) bytes that aren't JSON)")
}
exit((200..<300).contains(status) ? 0 : 1)
