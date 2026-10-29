import XCTest

/// One test cycle of Changelog on a simulator, against the Release Notes dev
/// server's fictional account, never production. `scripts/ui-test-cycle.sh`
/// readies the simulator (permissions, a location, the build) and runs it;
/// without a dev server token every test skips. Each test checks the dev
/// server's activity log too: exactly one note filed, with its files.
final class ChangelogUITests: XCTestCase {
  private var token = ""
  private var server = ""

  override func setUpWithError() throws {
    continueAfterFailure = false
    let environment = ProcessInfo.processInfo.environment
    guard let token = environment["CHANGELOG_DEV_TOKEN"], !token.isEmpty else {
      throw XCTSkip("No dev server token: run scripts/ui-test-cycle.sh.")
    }
    let server = environment["CHANGELOG_DEV_URL"] ?? "http://localhost:8790"
    guard let host = URL(string: server)?.host(), ["localhost", "127.0.0.1"].contains(host) else {
      throw XCTSkip("CHANGELOG_DEV_URL must be this Mac's dev server.")
    }
    self.token = token
    self.server = server
  }

  // MARK: The cycle

  @MainActor func testANote() async throws {
    let app = launch()
    let before = try await filed()
    type(note("A line"), into: app)
    app.buttons["Commit"].tap()
    expectFiled(app)
    let new = try await newNotes(since: before)
    XCTAssertEqual(new.first?.files ?? 0, 0)
  }

  @MainActor func testAPhoto() async throws {
    let app = launch()
    let before = try await filed()
    app.buttons["Add photos"].tap()
    // The picker runs out of process; its photos are images in a grid.
    let photo = app.images.matching(NSPredicate(format: "label BEGINSWITH 'Photo'")).firstMatch
    expect(photo, "the photo picker shows the library", in: app)
    photo.tap()
    if app.buttons["Add"].waitForExistence(timeout: 3) { app.buttons["Add"].tap() }
    expect(attachment(in: app), "the photo is on the draft", in: app)
    type(note("A photo"), into: app)
    app.buttons["Commit"].tap()
    expectFiled(app)
    let new = try await newNotes(since: before)
    XCTAssertEqual(new.first?.files, 1, "the note has its photo")
  }

  @MainActor func testHere() async throws {
    let app = launch()
    let before = try await filed()
    type(note("Somewhere"), into: app)
    app.buttons["Add where I am"].tap()
    // "Place: Here" until Here answers; its menu has no businesses yet.
    let place = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Place: ' AND label != 'Place: Here'")).firstMatch
    expect(place, "Here names the spot", in: app, timeout: 30)
    // A business nearby can be picked from the place's menu. The dev
    // server's --fake-places puts a Corner Café beside every spot.
    // The button spans the row; its menu opens from the words at its start.
    place.staticTexts.firstMatch.tap()
    let cafe = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Corner Café'")).firstMatch
    expect(cafe, "the menu lists the businesses nearby", in: app)
    cafe.tap()
    expect(app.buttons["Place: Corner Café"], "the note takes the business", in: app)
    app.buttons["Commit"].tap()
    expectFiled(app)
    _ = try await newNotes(since: before)
  }

  @MainActor func testAVoiceMemo() async throws {
    let app = launch()
    let before = try await filed()
    app.buttons["Record a voice memo"].tap()
    let stop = app.buttons["Add to the note"]
    expect(stop, "the recorder opens", in: app)
    if app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'The microphone is off'")).firstMatch.exists {
      XCTFail("The microphone is off for Changelog on this simulator")
    }
    // The screen answers while the microphone starts. A simulator's is the
    // Mac's, which can take minutes to answer, or never does.
    let couldnt = app.staticTexts["This phone couldn't record just now."]
    let deadline = Date.now.addingTimeInterval(180)
    while !stop.isEnabled, !couldnt.exists, Date.now < deadline { try await Task.sleep(for: .seconds(1)) }
    if couldnt.exists || !stop.isEnabled {
      throw XCTSkip("This simulator couldn't open the Mac's microphone (allow Simulator in the Mac's Privacy settings).")
    }
    try await Task.sleep(for: .seconds(2))
    stop.tap()
    expect(attachment(in: app), "the voice memo is on the draft", in: app)
    type(note("A voice memo"), into: app)
    app.buttons["Commit"].tap()
    expectFiled(app)
    let new = try await newNotes(since: before)
    XCTAssertEqual(new.first?.files, 1, "the note has its voice memo")
  }

  func testActivityAndTheBuild() throws {
    let app = launch()
    // Log opens with the keyboard up, over the tabs.
    hideKeyboard(app)
    app.tabBars.buttons["Activity"].tap()
    expect(app.staticTexts["Activity"], "Activity opens", in: app)
    app.tabBars.buttons["Settings"].tap()
    let build = app.staticTexts["build"]
    for _ in 0..<6 where !build.exists || !build.isHittable { app.swipeUp() }
    expect(build, "Settings names the build", in: app)
    XCTAssertTrue(build.label.hasPrefix("Changelog 0."), build.label)
    XCTAssertTrue(build.label.contains(", build "), build.label)
  }

  /// A photo shared from the Photos app files once, from the extension.
  @MainActor func testShareFromPhotos() async throws {
    // Signs the app in, so the extension finds the token and the server.
    launch().terminate()
    let before = try await filed()
    let photos = XCUIApplication(bundleIdentifier: "com.apple.mobileslideshow")
    photos.launch()
    for label in ["Continue", "Not Now", "OK"] where photos.buttons[label].waitForExistence(timeout: 2) {
      photos.buttons[label].tap()
    }
    // Photos opens where it was left: on a photo (the last run's), or the
    // library.
    let share = photos.buttons["Share"]
    if !share.waitForExistence(timeout: 3) {
      let first = photos.images.matching(identifier: "PXGGridLayout-Info").firstMatch
      expect(first, "Photos shows the library", in: photos)
      first.tap()
      expect(share, "a photo opens", in: photos)
    }
    share.tap()
    let changelog = photos.descendants(matching: .any).matching(NSPredicate(format: "label == 'Changelog'")).firstMatch
    if !changelog.waitForExistence(timeout: 8) {
      // Not in the row of apps yet: More lists every share extension.
      photos.descendants(matching: .any).matching(NSPredicate(format: "label == 'More'")).firstMatch.tap()
    }
    expect(changelog, "Changelog is in the share sheet", in: photos)
    changelog.tap()
    let commit = photos.buttons["Commit"]
    expect(commit, "the share sheet's Changelog opens", in: photos)
    let field = photos.textViews["Note"].exists ? photos.textViews["Note"] : photos.textFields["Note"]
    field.tap()
    field.typeText(note("Shared"))
    commit.tap()
    let filed = photos.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Filed in' OR label BEGINSWITH 'Unlocked'"))
      .firstMatch
    expect(filed, "the extension filed it", in: photos, timeout: 40)
    let new = try await newNotes(since: before)
    XCTAssertEqual(new.first?.files, 1, "the note has the photo")
    // The app, opened after, adopts nothing and sends nothing again.
    let app = launch()
    XCTAssertFalse(app.staticTexts["Waiting to send"].waitForExistence(timeout: 3))
    _ = try await newNotes(since: before)
  }

  // MARK: Helpers

  private func launch() -> XCUIApplication {
    let app = XCUIApplication()
    app.launchEnvironment["CHANGELOG_DEV_TOKEN"] = token
    app.launchEnvironment["CHANGELOG_DEV_URL"] = server
    app.launch()
    expect(app.buttons["Commit"], "signed in to the dev server", in: app, timeout: 30)
    return app
  }

  private func hideKeyboard(_ app: XCUIApplication) {
    for _ in 0..<3 where app.keyboards.count > 0 { app.collectionViews.firstMatch.swipeDown() }
  }

  /// A note's words, marked so a run's notes can be told apart.
  private func note(_ words: String) -> String {
    "\(words) \(UUID().uuidString.prefix(6).lowercased()) #uitest"
  }

  private func type(_ words: String, into app: XCUIApplication) {
    let field = app.textViews["Note"].exists ? app.textViews["Note"] : app.textFields["Note"]
    field.tap()
    field.typeText(words)
  }

  private func attachment(in app: XCUIApplication) -> XCUIElement {
    app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Take off'")).firstMatch
  }

  private func expectFiled(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
    let toast = app.staticTexts["toast"]
    expect(toast, "the note was filed", in: app, timeout: 40, file: file, line: line)
    XCTAssertTrue(toast.label.hasPrefix("Filed in") || toast.label.hasPrefix("Unlocked"), toast.label, file: file, line: line)
  }

  private func expect(_ element: XCUIElement, _ what: String, in app: XCUIApplication, timeout: TimeInterval = 15,
                      file: StaticString = #filePath, line: UInt = #line) {
    guard !element.waitForExistence(timeout: timeout) else { return }
    let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    shot.name = what
    shot.lifetime = .keepAlways
    add(shot)
    XCTFail("Expected: \(what)", file: file, line: line)
  }

  // MARK: The dev server's activity log

  struct Filed: Decodable, Sendable { let id: String; let kind: String; let files: Int? }
  private struct Page: Decodable { let items: [Filed] }

  /// The notes the activity log has filed, newest first.
  @MainActor private func filed() async throws -> [Filed] {
    try await Self.filed(server: server, token: token)
  }

  private static func filed(server: String, token: String) async throws -> [Filed] {
    var request = URLRequest(url: URL(string: "\(server)/v1/activity?limit=50&kinds=note")!)
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    let (data, _) = try await URLSession.shared.data(for: request)
    return try JSONDecoder().decode(Page.self, from: data).items.filter { $0.kind == "note.added" }
  }

  /// The notes filed since `before`, once there are some, after a moment
  /// more so a second copy would show; there must be exactly one.
  @discardableResult @MainActor
  private func newNotes(since before: [Filed], file: StaticString = #filePath, line: UInt = #line) async throws -> [Filed] {
    let old = Set(before.map(\.id))
    var new: [Filed] = []
    for _ in 0..<30 {
      new = try await filed().filter { !old.contains($0.id) }
      if !new.isEmpty { break }
      try await Task.sleep(for: .milliseconds(500))
    }
    try await Task.sleep(for: .seconds(2))
    new = try await filed().filter { !old.contains($0.id) }
    XCTAssertEqual(new.count, 1, "exactly one note filed", file: file, line: line)
    return new
  }
}
