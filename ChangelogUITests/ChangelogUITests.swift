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
    let words = note("A line")
    type(words, into: app)
    app.buttons["Commit"].tap()
    expectFiled(app)
    let new = try await newNotes(since: before)
    XCTAssertEqual(new.first?.files ?? 0, 0)
    // Today reads back what this token sent and shows its words.
    let row = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", words)).firstMatch
    expect(row, "Today shows the note's words", in: app)
    // A swipe's Delete asks first; the note goes only once confirmed. Log
    // keeps the keyboard up after Commit, over Today's newest rows.
    hideKeyboard(app)
    row.swipeLeft()
    app.buttons["Delete"].firstMatch.tap()
    expect(app.staticTexts["Delete this note?"], "deleting a note asks first", in: app)
    let confirm = app.sheets.buttons["Delete"].exists ? app.sheets.buttons["Delete"]
      : app.buttons.matching(identifier: "Delete").element(boundBy: app.buttons.matching(identifier: "Delete").count - 1)
    XCTAssertTrue(row.exists, "nothing is deleted before the confirmation")
    confirm.tap()
    XCTAssertTrue(row.waitForNonExistence(timeout: 20), "the note leaves Today")
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

  /// A picked moment fills the draft and sends nothing until Commit. A
  /// simulator has no Journaling Suggestions, so a debug build launched
  /// with `CHANGELOG_MOMENT` picks a fictional one: a walk two days ago by
  /// a lake, a song, and a video it leaves out.
  @MainActor func testAMoment() async throws {
    let app = launch(moment: true)
    let me = try await account()
    var before = try await filed()
    app.buttons["Add a moment"].tap()
    let day = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Files to '")).firstMatch
    expect(day, "the draft files to the moment's day", in: app)
    // Its version shows only when the app knows that day's, never today's.
    XCTAssertFalse(day.label.hasSuffix(", in \(me.version)"), day.label)
    let words = app.textViews["Note"].exists ? app.textViews["Note"] : app.textFields["Note"]
    XCTAssertTrue((words.value as? String ?? "").contains("Walked 3.2 mi in 48 min"), "the walk is one line")
    XCTAssertTrue((words.value as? String ?? "").contains("Listened to A Song by A Band"), "the song is one line")
    let video = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "doesn't keep video")).firstMatch
    expect(video, "the draft says the video is left out", in: app)
    let place = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Place: ' AND label != %@", "Place: The moment's place")).firstMatch
    expect(place, "Here names the moment's place", in: app, timeout: 30)
    // Nothing goes until Commit.
    try await Task.sleep(for: .seconds(2))
    let waiting = try await filed()
    XCTAssertEqual(waiting.count, before.count, "a moment sends nothing by itself")
    type(" \(note("A moment"))", into: app)
    let moment = Self.day(of: .now.addingTimeInterval(-2 * 86400), in: me.tz)
    app.buttons["Commit"].tap()
    expectFiled(app)
    let earlier = try await newNotes(since: before)
    XCTAssertEqual(earlier.first?.day, moment, "the note files to the moment's day")
    XCTAssertFalse(day.exists, "the next draft is today's")

    // "File to today" takes the day off and leaves the rest.
    before = try await filed()
    app.buttons["Add a moment"].tap()
    expect(day, "the draft files to the moment's day", in: app)
    expect(place, "Here names the moment's place", in: app, timeout: 30)
    // The button spans the row; its menu opens from the words at its start.
    day.buttons.firstMatch.tap()
    let today = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'File to today'")).firstMatch
    expect(today, "the day's menu has File to today", in: app)
    today.tap()
    XCTAssertTrue(day.waitForNonExistence(timeout: 5), "the draft is today's again")
    type(" \(note("A moment, today"))", into: app)
    app.buttons["Commit"].tap()
    expectFiled(app)
    let now = try await newNotes(since: before)
    XCTAssertEqual(now.first?.day, me.today, "the note files to today")
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
    // Settings hides its bar; Pinned tags, pushed from it, keeps Back and
    // Edit.
    let pinned = app.buttons["Pinned tags"]
    for _ in 0..<6 where !pinned.exists || !pinned.isHittable { app.swipeUp() }
    pinned.tap()
    expect(app.navigationBars.buttons["Edit"], "Pinned tags can be reordered", in: app)
    app.navigationBars.buttons.element(boundBy: 0).tap()
    let build = app.staticTexts["build"]
    for _ in 0..<6 where !build.exists || !build.isHittable { app.swipeUp() }
    expect(build, "Settings names the build", in: app)
    XCTAssertTrue(build.label.hasPrefix("Changelog 0."), build.label)
    XCTAssertTrue(build.label.contains(", build "), build.label)
  }

  /// A birthday added in Upcoming saves once, and a swipe deletes it.
  @MainActor func testUpcoming() async throws {
    let app = launch()
    hideKeyboard(app)
    app.tabBars.buttons["Upcoming"].tap()
    let add = app.buttons["Add a date"]
    expect(add, "Upcoming can add a date", in: app)
    add.tap()
    let title = "Ada \(UUID().uuidString.prefix(6).lowercased())"
    // The field's label is its prompt ("Whose birthday"), not "Title".
    let field = app.textFields["title"]
    expect(field, "the editor opens", in: app)
    field.tap()
    field.typeText(title)
    app.buttons["Save"].tap()
    let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
    expect(row, "the date is in the list", in: app)
    let saved = try await dates(titled: title)
    XCTAssertEqual(saved, 1, "saved once")
    row.swipeLeft()
    app.buttons["Delete"].firstMatch.tap()
    // The confirmation's Delete, not the swipe's.
    let confirm = app.sheets.buttons["Delete"].exists ? app.sheets.buttons["Delete"]
      : app.buttons.matching(identifier: "Delete").element(boundBy: app.buttons.matching(identifier: "Delete").count - 1)
    expect(confirm, "deleting asks first", in: app)
    confirm.tap()
    XCTAssertTrue(row.waitForNonExistence(timeout: 15), "the date leaves the list")
    let left = try await dates(titled: title)
    XCTAssertEqual(left, 0, "deleted on the server")
  }

  /// A widget's tap (or the New Note control) opens Log from any tab, with
  /// the keyboard up.
  @MainActor func testANewNoteLink() throws {
    let app = launch()
    hideKeyboard(app)
    app.tabBars.buttons["Settings"].tap()
    expect(app.staticTexts["Settings"], "Settings opens", in: app)
    app.open(URL(string: "com.yourversionnumber.changelog:new-note")!)
    expect(app.keyboards.firstMatch, "the keyboard comes up", in: app)
    XCTAssertTrue(app.tabBars.buttons["Log"].isSelected, "Log is open")
    // Asked again while Log is open, with the keyboard put away.
    hideKeyboard(app)
    app.open(URL(string: "com.yourversionnumber.changelog:new-note")!)
    expect(app.keyboards.firstMatch, "the keyboard comes up again", in: app)
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

  // MARK: Another account's notes

  /// A note written while signed in to another account, then signed in to
  /// this one: held, saying so, and sent only on "Send to this account",
  /// then exactly once, to this account.
  @MainActor func testAHeldNoteSent() async throws {
    let words = note("Held")
    let (app, row, before) = try await heldNote(words)
    row.buttons["Send to this account"].tap()
    expectFiled(app)
    try await newNotes(since: before)
    // Today shows it now, as this account's own; nothing of it is held.
    XCTAssertTrue(row.staticTexts["held"].waitForNonExistence(timeout: 10), "it no longer waits")
  }

  /// The same note deleted instead: Delete asks first, and the note goes
  /// from the phone, never sent.
  @MainActor func testAHeldNoteDeleted() async throws {
    let words = note("Held")
    let (app, row, before) = try await heldNote(words)
    row.buttons["Delete"].tap()
    expect(app.staticTexts["Delete this note?"], "deleting a held note asks first", in: app)
    XCTAssertTrue(row.exists, "nothing is deleted before the confirmation")
    let confirm = app.sheets.buttons["Delete"].exists ? app.sheets.buttons["Delete"]
      : app.buttons.matching(identifier: "Delete").element(boundBy: app.buttons.matching(identifier: "Delete").count - 1)
    confirm.tap()
    XCTAssertTrue(row.waitForNonExistence(timeout: 10), "the note leaves the phone")
    try await Task.sleep(for: .seconds(3))
    let now = Set(try await filed().map(\.id))
    XCTAssertTrue(now.isSubset(of: before.map(\.id)), "a deleted held note is never sent")
  }

  /// Signs in to a new fictional account and writes `words` there, its
  /// token ended so the note waits; then opens the app signed in to the dev
  /// server's own account, where the note is held. Answers the app, the
  /// note's row, and this account's notes before anything is chosen.
  @MainActor
  private func heldNote(_ words: String) async throws -> (XCUIApplication, XCUIElement, [Filed]) {
    let other = try await Self.newAccountToken(server: server)
    let first = launch(as: other)
    type(words, into: first)
    try await Self.revoke(other, server: server)
    first.buttons["Commit"].tap()
    expect(first.staticTexts["signed-out-reason"], "the ended token signs the app out, the note waiting", in: first, timeout: 40)
    first.terminate()

    let before = try await filed()
    let app = launch()
    let row = app.cells.containing(NSPredicate(format: "label CONTAINS %@", words)).firstMatch
    let held = row.staticTexts["held"]
    expect(held, "the other account's note is held", in: app, timeout: 20)
    XCTAssertEqual(held.label, "Written while signed in to another account.")
    // Nothing held goes by itself.
    try await Task.sleep(for: .seconds(3))
    let now = Set(try await filed().map(\.id))
    XCTAssertTrue(now.isSubset(of: before.map(\.id)), "a held note never goes without the owner's choice")
    return (app, row, before)
  }

  // MARK: Helpers

  /// The app signed in to the dev server: its own account, or another
  /// account's token; with a moment to pick, for the Moments test.
  private func launch(as other: String? = nil, moment: Bool = false) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchEnvironment["CHANGELOG_DEV_TOKEN"] = other ?? token
    app.launchEnvironment["CHANGELOG_DEV_URL"] = server
    if moment { app.launchEnvironment["CHANGELOG_MOMENT"] = "1" }
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

  // MARK: Another fictional account

  private struct Refused: Error { let path: String; let status: Int }

  /// A token for a new fictional account on the dev server, made as its web
  /// pages make one: the sign-in code from the dev server's mailbox, the new
  /// account's settings, then the token. The dev server sends at most 20
  /// sign-in emails an hour to this Mac, one a run of each held-note test.
  private static func newAccountToken(server: String) async throws -> String {
    let email = "held-\(UUID().uuidString.prefix(8).lowercased())@example.com"
    _ = try await web("POST", "/api/auth/start", ["email": email], server: server)
    let (mail, _) = try await web("GET", "/dev-mail/?to=\(email)", nil, server: server)
    let page = String(decoding: mail, as: UTF8.self)
    let code = try XCTUnwrap(page.range(of: "code where you asked: [0-9]+", options: .regularExpression)
      .flatMap { page[$0].split(separator: " ").last.map(String.init) }, "the dev mailbox has the code")
    let (_, verified) = try await web("POST", "/api/auth/verify", ["email": email, "code": code], server: server)
    // The session cookie is Secure, which URLSession won't send over http.
    let set = verified.value(forHTTPHeaderField: "Set-Cookie") ?? ""
    let cookie = try XCTUnwrap(set.range(of: "__Host-rn=[^;, ]+", options: .regularExpression).map { String(set[$0]) },
                               "signed in on the web")
    _ = try await web("PUT", "/api/me", [
      "birthday": "1985-03-02", "send_time": "06:00",
      "place": ["name": "Minneapolis", "region": "Minnesota", "country": "United States", "tz": "America/Chicago",
                "lat": 44.98, "lon": -93.26],
    ], cookie: cookie, server: server)
    let (made, _) = try await web("POST", "/api/tokens", [
      "name": "Changelog", "scopes": ["notes:write", "media:write", "activity"], "expiry": "never",
    ], cookie: cookie, server: server)
    struct Made: Decodable { let token: String }
    return try JSONDecoder().decode(Made.self, from: made).token
  }

  /// One call to the dev server's web API, as its own pages make it.
  private static func web(_ method: String, _ path: String, _ body: [String: Any]?, cookie: String? = nil,
                          server: String) async throws -> (Data, HTTPURLResponse) {
    var request = URLRequest(url: URL(string: server + path)!)
    request.httpMethod = method
    request.setValue(server, forHTTPHeaderField: "Origin")
    request.httpShouldHandleCookies = false
    if let cookie { request.setValue(cookie, forHTTPHeaderField: "Cookie") }
    if let body {
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSONSerialization.data(withJSONObject: body)
    }
    let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
    let http = try XCTUnwrap(response as? HTTPURLResponse)
    guard (200..<300).contains(http.statusCode) else { throw Refused(path: path, status: http.statusCode) }
    return (data, http)
  }

  /// Ends a token, as ending it on the web would.
  private static func revoke(_ token: String, server: String) async throws {
    var request = URLRequest(url: URL(string: "\(server)/v1/token")!)
    request.httpMethod = "DELETE"
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    let (_, response) = try await URLSession.shared.data(for: request)
    XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 204, "the other account's token is ended")
  }

  // MARK: The dev server's activity log

  struct Filed: Decodable, Sendable { let id: String; let kind: String; let files: Int?; let day: String? }
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

  struct Account: Decodable, Sendable { let today: String; let tz: String; let version: String }

  /// The dev server account's day and time zone.
  @MainActor private func account() async throws -> Account {
    try await Self.account(server: server, token: token)
  }

  private static func account(server: String, token: String) async throws -> Account {
    var request = URLRequest(url: URL(string: "\(server)/v1/me")!)
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    let (data, _) = try await URLSession.shared.data(for: request)
    return try JSONDecoder().decode(Account.self, from: data)
  }

  /// `date`'s day in the account's time zone, as `/v1` writes days.
  private static func day(of date: Date, in zone: String) -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: zone) ?? .current
    let c = calendar.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
  }

  private struct Dates: Decodable {
    struct Entry: Decodable { let title: String }
    let entries: [Entry]
  }

  /// How many Upcoming dates on the dev server have this title.
  @MainActor private func dates(titled title: String) async throws -> Int {
    try await Self.dates(titled: title, server: server, token: token)
  }

  private static func dates(titled title: String, server: String, token: String) async throws -> Int {
    var request = URLRequest(url: URL(string: "\(server)/v1/upcoming")!)
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    let (data, _) = try await URLSession.shared.data(for: request)
    return try JSONDecoder().decode(Dates.self, from: data).entries.filter { $0.title == title }.count
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
