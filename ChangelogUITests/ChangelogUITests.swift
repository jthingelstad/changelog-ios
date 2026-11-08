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
    // The sheet, whether or not the microphone answers: one that fails at
    // once shows no stop button.
    expect(app.navigationBars["Voice memo"], "the recorder opens", in: app)
    if app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'The microphone is off'")).firstMatch.exists {
      XCTFail("The microphone is off for Changelog on this simulator")
    }
    // The screen answers while the microphone starts. A simulator's is the
    // Mac's, which can take minutes to answer, or never does.
    let couldnt = app.staticTexts["This phone couldn't record just now."]
    let deadline = Date.now.addingTimeInterval(180)
    while !(stop.exists && stop.isEnabled), !couldnt.exists, Date.now < deadline { try await Task.sleep(for: .seconds(1)) }
    if couldnt.exists || !(stop.exists && stop.isEnabled) {
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

  /// The dev server's account is its administrator, which `/v1/me` counts
  /// as a Supporting Member (API 1.12.0): Settings offers all five icons,
  /// and choosing one makes it the app's, after iOS's own alert.
  @MainActor func testAppIcons() throws {
    let app = launch()
    hideKeyboard(app)
    app.tabBars.buttons["Settings"].tap()
    let copper = app.buttons["app-icon-Copper"], versions = app.buttons["app-icon-Versions"]
    for _ in 0..<6 where !copper.exists || !copper.isHittable { app.swipeUp() }
    expect(copper, "a member is offered the icons", in: app)
    for name in ["Versions", "Paper", "Copper", "Terminal", "Afterglow"] {
      XCTAssertTrue(app.buttons["app-icon-\(name)"].exists, name)
    }
    XCTAssertTrue(versions.isSelected, "Versions is on to begin with")
    keep(app, "App icon section")
    copper.tap()
    okIconAlert()
    XCTAssertTrue(copper.wait(for: \.isSelected, toEqual: true, timeout: 10), "Copper is on once chosen")
    XCUIDevice.shared.press(.home)
    keep(XCUIApplication(bundleIdentifier: "com.apple.springboard"), "Home Screen with Copper")
    app.activate()
    versions.tap()
    okIconAlert()
    XCTAssertTrue(versions.wait(for: \.isSelected, toEqual: true, timeout: 10), "Versions is back")
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

  /// The list says how far off each date is, and sets them under their months.
  @MainActor func testUpcomingMonths() async throws {
    let (_, data) = try await Self.statusOfMe(server: server, token: token)
    let today = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])["today"] as? String
    let mark = UUID().uuidString.prefix(6).lowercased()
    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = TimeZone(secondsFromGMT: 0)!
    let day = DateFormatter()
    day.calendar = utc
    day.timeZone = utc.timeZone
    day.locale = Locale(identifier: "en_US_POSIX")
    day.dateFormat = "yyyy-MM-dd"
    let start = try XCTUnwrap(day.date(from: try XCTUnwrap(today)))
    let on = { (ahead: Int) in day.string(from: utc.date(byAdding: .day, value: ahead, to: start)!) }
    // A date more than a year off shows its year in its month's heading.
    let dates = [(1, "Tomorrow"), (7, "In 7 days"), (23, "3 weeks 2 days"), (400, "57 weeks 1 day")]
    var ids: [(id: String, revision: Int)] = []
    for (ahead, _) in dates {
      ids.append(try await Self.addDate("Soon \(mark) \(ahead)", on: on(ahead), server: server, token: token))
    }

    let app = launch()
    hideKeyboard(app)
    app.tabBars.buttons["Upcoming"].tap()
    let list = app.collectionViews.firstMatch
    for (ahead, words) in dates {
      let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Soon \(mark) \(ahead)")).firstMatch
      for _ in 0..<10 where !(row.exists && row.isHittable) { list.swipeUp(velocity: .slow) }
      expect(row, "a date \(ahead) days off", in: app, timeout: 15)
      XCTAssertTrue(row.label.localizedCaseInsensitiveContains(words), "\(row.label) says \(words)")
    }
    let far = try XCTUnwrap(utc.date(byAdding: .day, value: 400, to: start))
    day.dateFormat = "LLLL yyyy"
    let heading = app.staticTexts.matching(NSPredicate(format: "label ==[c] %@", day.string(from: far))).firstMatch
    expect(heading, "its month's heading says the year", in: app, timeout: 15)
    keep(app, "Upcoming by month")
    for (id, revision) in ids { try await Self.removeDate(id, revision: revision, server: server, token: token) }
  }

  /// The map: a place's stops are one pin that opens them, then one stop's page;
  /// and the Check In control's link, which opens Activity and says so. A control
  /// itself can't be pressed from a test (`docs/PHONE-TEST.md`).
  @MainActor func testCheckInMapAndControl() async throws {
    let scopes = ["notes:write", "media:write", "upcoming", "activity", "notes:all"]
    let owner = try await Self.tokenOnThisAccount(scopes, server: server)
    try await Self.deleteCheckIns(server: server, token: owner)
    try await Self.forgetPlaces(server: server, token: owner)
    try await Self.send("POST", "/v1/check-ins/places", ["name": "Workshop", "lat": 44.9778, "lon": -93.2650],
                        server: server, token: owner)
    for (arrived, left, lat, lon) in [("2026-11-02T15:00:00Z", "2026-11-02T16:00:00Z", 44.9778, -93.2650),
                                      ("2026-11-03T15:00:00Z", "2026-11-03T16:30:00Z", 44.9779, -93.2651),
                                      ("2026-11-04T15:00:00Z", "2026-11-04T15:40:00Z", 44.9100, -93.2000)] {
      try await Self.send("POST", "/v1/check-ins",
                          ["arrived": arrived, "left": left, "lat": lat, "lon": lon, "source": "visit"],
                          server: server, token: owner)
    }
    let app = launch(as: owner)
    hideKeyboard(app)

    app.tabBars.buttons["Activity"].tap()
    let open = app.buttons["Map of check-ins"]
    expect(open, "Activity opens the map", in: app, timeout: 15)
    open.tap()
    let pin = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Workshop'")).firstMatch
    expect(pin, "a place's stops are a pin", in: app, timeout: 20)
    keep(app, "The map of check-ins")
    pin.tap()
    let hour = app.buttons.matching(NSPredicate(format: "label CONTAINS '60 min'")).firstMatch
    expect(hour, "the pin lists its older stop", in: app, timeout: 15)
    XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS '90 min'")).firstMatch.exists,
                  "and its newer one")
    keep(app, "A place's stops")
    hour.tap()
    expect(app.buttons["Write about this"], "a stop opens its page", in: app, timeout: 15)
    keep(app, "A stop from the map")
    app.navigationBars["Check-in"].buttons.firstMatch.tap()
    let close = app.buttons["Close"]
    expect(close, "back to the place's stops", in: app)
    close.tap()
    XCTAssertTrue(close.waitForNonExistence(timeout: 5), "the sheet closes")

    // Where the control goes: Activity, a fix, and it says so.
    app.tabBars.buttons["Settings"].tap()
    app.open(URL(string: "com.yourversionnumber.changelog:check-in")!)
    let said = app.staticTexts["toast"]
    expect(said, "a check-in from outside says so", in: app, timeout: 30)
    XCTAssertTrue(said.label.hasPrefix("Checked in at"), said.label)
    XCTAssertTrue(app.tabBars.buttons["Activity"].isSelected, "it opens Activity")
    keep(app, "Check in from the control")
    try await Self.deleteCheckIns(server: server, token: owner)
    try await Self.forgetPlaces(server: server, token: owner)
  }

  /// Check-ins from the switch on: a visit iOS reports, one row and one stay;
  /// its page; a name for one stop, then one remembered; Write about this;
  /// Check in now; and everything deleted. A simulator never reports a visit,
  /// so `CHANGELOG_VISIT` stands in for iOS, and real delivery is for a phone
  /// (`docs/PHONE-TEST.md`).
  @MainActor func testCheckIns() async throws {
    let scopes = ["notes:write", "media:write", "upcoming", "activity", "notes:all"]
    let owner = try await Self.tokenOnThisAccount(scopes, server: server)
    try await Self.deleteCheckIns(server: server, token: owner)
    try await Self.forgetPlaces(server: server, token: owner)
    let app = launch(as: owner, more: ["CHANGELOG_VISIT": "1"])
    let stops = NSPredicate(format: "label BEGINSWITH 'Checked in at'")
    hideKeyboard(app)

    app.tabBars.buttons["Settings"].tap()
    let toggle = app.switches["Notice where I stop"]
    for _ in 0..<12 where !(toggle.exists && toggle.isHittable) { app.collectionViews.firstMatch.swipeUp(velocity: .slow) }
    expect(toggle, "Settings has the switch", in: app)
    XCTAssertEqual(toggle.value as? String, "0", "it is off until turned on")
    keep(app, "Check-ins off")
    toggle.switches.firstMatch.tap()
    XCTAssertEqual(toggle.value as? String, "1", "it turns on")
    keep(app, "Check-ins on")

    // The arrival and its leaving are one stay on the server, and one row.
    app.tabBars.buttons["Activity"].tap()
    let filter = app.buttons["Check-ins"]
    expect(filter, "Activity can show just check-ins", in: app, timeout: 15)
    filter.tap()
    let row = app.buttons.matching(stops).firstMatch
    // At the hour it began, so below whatever else has happened since.
    for _ in 0..<8 where !row.waitForExistence(timeout: 4) { app.collectionViews.firstMatch.swipeUp(velocity: .slow) }
    expect(row, "the stop is a row in Activity", in: app, timeout: 15)
    XCTAssertEqual(app.buttons.matching(stops).count, 1, "an arrival and its leaving are one row")
    XCTAssertTrue(row.label.contains("50 min"), "the row says how long: \(row.label)")
    keep(app, "Check-ins in Activity")

    // Its page, then a name on this stop alone.
    row.tap()
    expect(app.buttons["Write about this"], "the row opens its page", in: app, timeout: 15)
    expect(app.staticTexts["The neighbourhood, until you name it."], "it says where the name came from", in: app)
    keep(app, "A check-in")
    app.buttons["Name it"].tap()
    let name = app.textFields["Name"]
    expect(name, "naming it asks for a name", in: app)
    let nearby = app.buttons["Corner Café"]
    expect(nearby, "the businesses nearby are offered", in: app, timeout: 15)
    keep(app, "Naming a check-in")
    name.tap()
    name.typeText("Workshop")
    app.buttons["Save name"].tap()
    expect(app.staticTexts["You named this stop."], "the name is the stop's own", in: app, timeout: 15)
    expect(app.staticTexts["Workshop"], "the page takes it", in: app)

    // Remembered: the name goes on the place, and the stop's own comes off.
    app.buttons["Change the name"].tap()
    let remember = app.switches["Remember this place"]
    expect(remember, "a token that may change every note can remember", in: app, timeout: 15)
    XCTAssertEqual(remember.value as? String, "0", "Remember is off by default")
    remember.switches.firstMatch.tap()
    app.buttons["Save name"].tap()
    expect(app.staticTexts["A place you remember. Rename or forget it in Settings."], "the place names it now", in: app, timeout: 15)
    expect(app.staticTexts["Workshop"], "with the same name", in: app)
    keep(app, "A remembered place")

    // Write about this: Log, at that place, and nothing sent.
    let before = try await filed()
    app.buttons["Write about this"].tap()
    expect(app.buttons["Commit"], "it opens Log", in: app, timeout: 15)
    XCTAssertTrue(app.tabBars.buttons["Log"].isSelected, "Log is open")
    expect(app.buttons["Place: Workshop"], "the note starts at the place", in: app, timeout: 30)
    keep(app, "Writing about a check-in")
    let after = try await filed()
    XCTAssertEqual(after.count, before.count, "nothing is sent until Commit")
    type(note("About that stop"), into: app)
    app.buttons["Commit"].tap()
    expectFiled(app)
    let written = try await newNotes(since: before)
    XCTAssertEqual(written.count, 1, "it files one note")
    hideKeyboard(app)
    // The toast has to go before the next one can be told from it.
    XCTAssertTrue(app.staticTexts["toast"].waitForNonExistence(timeout: 10))

    // Check in now: a tap, said so, and its own row.
    let now = app.buttons["Check in now"]
    expect(now, "Log has Check in now", in: app)
    now.tap()
    let said = app.staticTexts["toast"]
    expect(said, "a tap says it went", in: app, timeout: 30)
    XCTAssertEqual(said.label, "Checked in at Workshop.", "by the name that place has")
    keep(app, "Check in now")
    // Back at the same place, it merges with the stop before it (the design's
    // merge rule), so still one row.
    app.tabBars.buttons["Activity"].tap()
    app.navigationBars.buttons.firstMatch.tap()
    let tapped = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Checked in at Workshop'")).firstMatch
    for _ in 0..<8 where !tapped.waitForExistence(timeout: 4) { app.collectionViews.firstMatch.swipeUp(velocity: .slow) }
    expect(tapped, "the stop is still a row", in: app, timeout: 15)
    XCTAssertEqual(app.buttons.matching(stops).count, 1, "a tap at the same place merges")

    // Deleting one from its page.
    tapped.tap()
    let delete = app.buttons["Delete"]
    expect(delete, "a check-in can be deleted", in: app, timeout: 15)
    for _ in 0..<6 where !delete.isHittable { app.collectionViews.firstMatch.swipeUp(velocity: .slow) }
    delete.tap()
    let confirm = app.buttons.matching(identifier: "Delete").firstMatch
    expect(confirm, "deleting asks first", in: app)
    let sheet = app.sheets.buttons["Delete"]
    (sheet.exists ? sheet : confirm).tap()
    XCTAssertTrue(app.buttons["Write about this"].waitForNonExistence(timeout: 15), "gone, it goes back to Activity")

    // Settings: the place, then all of them, then the switch back off.
    app.tabBars.buttons["Settings"].tap()
    let places = app.buttons["Remembered places"]
    for _ in 0..<12 where !(places.exists && places.isHittable) { app.collectionViews.firstMatch.swipeUp(velocity: .slow) }
    places.tap()
    let kept = app.staticTexts["Workshop"]
    expect(kept, "Settings lists the place", in: app, timeout: 15)
    keep(app, "Remembered places")
    kept.swipeLeft()
    let forget = app.buttons["Forget"]
    expect(forget, "a place can be forgotten", in: app)
    forget.tap()
    let sure = app.buttons.matching(NSPredicate(format: "label == 'Forget'")).firstMatch
    expect(sure, "forgetting asks first", in: app)
    sure.tap()
    expect(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'None yet'")).firstMatch, "the place went", in: app, timeout: 15)
    app.navigationBars.buttons.firstMatch.tap()

    let all = app.buttons["Delete all check-ins"]
    for _ in 0..<6 where !(all.exists && all.isHittable) { app.collectionViews.firstMatch.swipeUp(velocity: .slow) }
    all.tap()
    let everyOne = app.buttons.matching(identifier: "Delete").firstMatch
    expect(everyOne, "deleting them all asks first", in: app)
    everyOne.tap()
    expect(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Deleted '")).firstMatch, "they went", in: app, timeout: 15)
    toggle.switches.firstMatch.tap()
    XCTAssertEqual(toggle.value as? String, "0", "off again, so the next test finds it as it was")
  }

  /// Check in now needs no switch: a tap from Log, said so, with its own row.
  @MainActor func testCheckInNow() async throws {
    let app = launch()
    hideKeyboard(app)
    let now = app.buttons["Check in now"]
    expect(now, "Log has Check in now", in: app)
    now.tap()
    let said = app.staticTexts["toast"]
    expect(said, "a tap says it went", in: app, timeout: 30)
    XCTAssertTrue(said.label.hasPrefix("Checked in at "), said.label)
    keep(app, "Check in now")
    try await Self.deleteCheckIns(server: server, token: token)
  }

  /// What the visits test left on a phone stays readable and deletable, and
  /// nothing goes up. `CHANGELOG_OLD_VISITS` makes the file as the test did.
  @MainActor func testVisitsFromTheTest() throws {
    let app = launch(more: ["CHANGELOG_OLD_VISITS": "1"])
    hideKeyboard(app)
    app.tabBars.buttons["Settings"].tap()
    let page = app.buttons["Visits from the test"]
    for _ in 0..<12 where !(page.exists && page.isHittable) { app.collectionViews.firstMatch.swipeUp(velocity: .slow) }
    expect(page, "the test's file is still there", in: app)
    page.tap()
    expect(app.staticTexts["1 stop over 1 day"], "it reads as it did", in: app, timeout: 15)
    keep(app, "Visits from the test")
    let delete = app.buttons["Delete them all"]
    for _ in 0..<6 where !(delete.exists && delete.isHittable) { app.collectionViews.firstMatch.swipeUp(velocity: .slow) }
    delete.tap()
    let confirm = app.buttons.matching(identifier: "Delete").firstMatch
    expect(confirm, "deleting asks first", in: app)
    confirm.tap()
    expect(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Nothing here'")).firstMatch, "they went", in: app, timeout: 15)
    app.navigationBars.buttons.firstMatch.tap()
    XCTAssertFalse(page.waitForExistence(timeout: 3), "with the file gone, Settings stops offering it")
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
    // Log opens with the keyboard up, over the waiting rows.
    hideKeyboard(app)
    // Nothing held goes by itself.
    try await Task.sleep(for: .seconds(3))
    let now = Set(try await filed().map(\.id))
    XCTAssertTrue(now.isSubset(of: before.map(\.id)), "a held note never goes without the owner's choice")
    return (app, row, before)
  }

  // MARK: Reading

  /// The one button trades a four-tick token for one that may read; another
  /// channel's note opens whole; the lock keeps it back and Log still writes.
  /// A note's files changed from its edit: a photo put on, then taken off,
  /// which asks first. Release Notes has each change once it is saved.
  @MainActor func testEditFiles() async throws {
    let words = note("Files to change")
    let made = try await Self.addNoteNamed(words, server: server, token: token)
    let (server, token) = (self.server, self.token)
    addTeardownBlock { try await Self.deleteNote(made, server: server, token: token) }
    let app = launch()
    hideKeyboard(app)
    let row = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", words)).firstMatch
    for _ in 0..<8 where !(row.waitForExistence(timeout: 3) && row.isHittable) { app.collectionViews.firstMatch.swipeUp(velocity: .slow) }
    expect(row, "Today shows the note", in: app)

    row.swipeLeft()
    app.buttons["Edit"].firstMatch.tap()
    let add = app.buttons["edit.addPhotos"]
    expect(add, "the edit offers files", in: app)
    add.tap()
    // The library's photos, as "Photo, March 30, 2018…": not the edit's own "Photo On A Rectangle".
    let photo = app.images.matching(NSPredicate(format: "label BEGINSWITH 'Photo,'")).firstMatch
    expect(photo, "the photo picker shows the library", in: app)
    photo.tap()
    if app.buttons["Add"].waitForExistence(timeout: 3) { app.buttons["Add"].tap() }
    expect(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Take off Photo'")).firstMatch, "the photo waits on the edit", in: app)
    keep(app, "A photo to put on")
    app.navigationBars.buttons["Save"].tap()
    try await expectFiles(1, on: made, "the photo went on the note")

    for _ in 0..<8 where !(row.waitForExistence(timeout: 3) && row.isHittable) { app.collectionViews.firstMatch.swipeUp(velocity: .slow) }
    row.swipeLeft()
    app.buttons["Edit"].firstMatch.tap()
    let off = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Take off Photo'")).firstMatch
    expect(off, "the edit shows the note's photo", in: app, timeout: 20)
    off.tap()
    expect(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Keep Photo'")).firstMatch, "a file taken off can be kept", in: app)
    keep(app, "A photo to take off")
    app.navigationBars.buttons["Save"].tap()
    expect(app.staticTexts["Take this file off the note?"], "taking a file off asks first", in: app)
    let before = try await Self.noteFiles(made, server: server, token: token)
    XCTAssertEqual(before, 1, "nothing goes before the confirmation")
    app.buttons["Take It Off"].firstMatch.tap()
    try await expectFiles(0, on: made, "the photo came off the note")
  }

  @MainActor func testReading() async throws {
    let scopes = ["notes:write", "media:write", "upcoming", "activity"]
    let old = try await Self.tokenOnThisAccount(scopes, server: server)
    let reader = try await Self.tokenOnThisAccount(scopes + ["notes:all"], server: server)
    let words = note("From another channel")
    try await Self.addNote(words, server: server, token: token)
    let elsewhere = NSPredicate(format: "label CONTAINS %@", words)
    let mark = String(UUID().uuidString.prefix(6).lowercased())
    try await Self.addNote("Rich \(mark) **bold** and *leaning*\n\n- first\n- second\n\n> quoted", markup: "rich",
                           server: server, token: token)

    var app = launch(as: old, more: ["CHANGELOG_SWITCH_TOKEN": reader, "CHANGELOG_LOCK_ANSWER": "yes"])
    hideKeyboard(app)
    app.tabBars.buttons["Notes"].tap()
    let allow = app.buttons["Allow reading"]
    expect(allow, "the Notes tab offers reading", in: app, timeout: 15)
    allow.tap()
    let row = app.descendants(matching: .any).matching(elsewhere).firstMatch
    // Today lists oldest first, and the dev server's today fills up over a morning of runs.
    expect(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Today'")).firstMatch, "Notes reads", in: app, timeout: 30)
    for _ in 0..<8 where !(row.waitForExistence(timeout: 3) && row.isHittable) { app.collectionViews.firstMatch.swipeUp(velocity: .slow) }
    expect(row, "a note from elsewhere reads whole", in: app, timeout: 15)
    keep(app, "Notes")
    let (status, _) = try await Self.statusOfMe(server: server, token: old)
    XCTAssertEqual(status, 401, "the old token ended")
    row.tap()
    expect(app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'via '")).firstMatch,
           "the note says where it came from", in: app, timeout: 15)
    keep(app, "A note")
    app.navigationBars.buttons.firstMatch.tap()

    // A rich note: its marks are set, not shown.
    let rich = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Rich \(mark)")).firstMatch
    expect(rich, "the rich note is on the list", in: app, timeout: 15)
    keep(app, "A rich note in the list")
    XCTAssertFalse(rich.label.contains("**"), "its marks don't show")
    rich.tap()
    expect(app.staticTexts["second"], "its list is a list", in: app, timeout: 15)
    keep(app, "A rich note")
    app.navigationBars.buttons.firstMatch.tap()

    // A day before today, with files on one of its notes.
    let list = app.collectionViews.firstMatch
    let day = list.buttons.matching(NSPredicate(format: "label CONTAINS 'files'")).firstMatch
    for _ in 0..<6 where !(day.exists && day.isHittable) { list.swipeUp(velocity: .slow) }
    expect(day, "an earlier day with files", in: app, timeout: 15)
    keep(app, "Earlier")
    day.tap()
    let filed = app.collectionViews.firstMatch.buttons.firstMatch
    expect(filed, "the day opens with its note", in: app, timeout: 15)
    keep(app, "A past day")
    filed.tap()
    // The picture itself, not its box: the box stands there whether or not it came.
    expect(app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Photo' AND value == 'Showing'")).firstMatch,
           "the note's photo shows", in: app, timeout: 15)
    keep(app, "A note with files")
    // A recording plays in place: fetched on Play, with its length, and Play
    // back once it ends (the dev server's is a second of quiet).
    let play = app.buttons["Play Voice memo"]
    expect(play, "the voice memo offers Play", in: app, timeout: 15)
    play.tap()
    let line = app.sliders["Voice memo"]
    expect(line, "the voice memo plays in place", in: app, timeout: 15)
    keep(app, "A voice memo playing")
    XCTAssertTrue((line.value as? String)?.hasSuffix("of 0:01") == true, "its length shows: \(String(describing: line.value))")
    expect(play, "it ends, and Play is back", in: app, timeout: 15)
    app.navigationBars.buttons.firstMatch.tap()
    app.navigationBars.buttons.firstMatch.tap()

    // Activity's rows open their notes. The newest row filed is a note deleted
    // since, which says so; the one before it is the rich note, or the note
    // from elsewhere when both were filed in the same second.
    let spent = try await Self.addNoteNamed("Gone soon \(mark)", server: server, token: reader)
    try await Self.deleteNote(spent, server: server, token: reader)
    app.tabBars.buttons["Activity"].tap()
    let filedRows = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Filed in'"))
    expect(filedRows.firstMatch, "Activity's rows open", in: app, timeout: 15)
    keep(app, "Activity")
    filedRows.element(boundBy: 0).tap()
    expect(app.staticTexts["This note is gone: it was deleted somewhere else."], "a note since deleted says so", in: app, timeout: 15)
    app.navigationBars.buttons.firstMatch.tap()
    expect(filedRows.element(boundBy: 1), "the list is still there", in: app, timeout: 15)
    filedRows.element(boundBy: 1).tap()
    let opened = NSPredicate(format: "label == 'second' OR label CONTAINS %@", words)
    expect(app.staticTexts.matching(opened).firstMatch, "a row opens its note", in: app, timeout: 15)
    keep(app, "A note from Activity")
    app.navigationBars.buttons.firstMatch.tap()
    XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Deleted from'")).firstMatch.exists,
                   "a deleted note's row opens nothing")

    app.tabBars.buttons["Log"].tap()
    // Log takes the keyboard as it opens, and that covers Today.
    expect(app.keyboards.firstMatch, "Log is ready to write", in: app)
    hideKeyboard(app)
    let todayRow = app.descendants(matching: .any).matching(elsewhere).firstMatch
    for _ in 0..<6 where !todayRow.waitForExistence(timeout: 3) { app.collectionViews.firstMatch.swipeUp(velocity: .slow) }
    expect(todayRow, "Log's Today shows its words", in: app, timeout: 15)

    turnLock(in: app, on: true)
    app.terminate()

    // Face ID says no: nothing from elsewhere shows, and Log still takes a note.
    app = launch(as: reader, more: ["CHANGELOG_LOCK_ANSWER": "no"])
    XCTAssertFalse(app.descendants(matching: .any).matching(elsewhere).firstMatch.waitForExistence(timeout: 5),
                   "locked, Log's Today keeps the words back")
    hideKeyboard(app)
    app.tabBars.buttons["Notes"].tap()
    expect(app.buttons["Unlock"], "Notes is locked", in: app, timeout: 15)
    XCTAssertFalse(app.descendants(matching: .any).matching(elsewhere).firstMatch.exists)
    keep(app, "Locked")
    // Activity still reads, wordless, and its rows open nothing while locked.
    app.tabBars.buttons["Activity"].tap()
    expect(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Filed in'")).firstMatch, "locked, Activity reads", in: app, timeout: 15)
    XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Filed in'")).firstMatch.exists,
                   "locked, a row opens nothing")
    app.terminate()

    // Yes: it opens. Off again, so the next test finds it as it was.
    app = launch(as: reader, more: ["CHANGELOG_LOCK_ANSWER": "yes"])
    hideKeyboard(app)
    app.tabBars.buttons["Notes"].tap()
    expect(app.descendants(matching: .any).matching(elsewhere).firstMatch, "unlocked, it reads", in: app, timeout: 30)
    turnLock(in: app, on: false)
    app.terminate()
    try await Self.revoke(reader, server: server)
  }

  /// Notes' search, across every year, and On this day, on notes filed to
  /// this day in earlier years for the test.
  @MainActor func testSearchAndOnThisDay() async throws {
    let reader = try await Self.tokenOnThisAccount(["notes:write", "media:write", "upcoming", "activity", "notes:all"],
                                                   server: server)
    let (_, me) = try await Self.statusOfMe(server: server, token: reader)
    let today = try XCTUnwrap((try JSONSerialization.jsonObject(with: me) as? [String: Any])?["today"] as? String)
    guard !today.hasSuffix("-02-29") else { throw XCTSkip("A leap day: no year before has it.") }
    let year = try XCTUnwrap(Int(today.prefix(4))), monthDay = today.dropFirst(4)
    let mark = String(UUID().uuidString.prefix(6).lowercased())
    var made: [(date: String, id: String)] = []
    // Four last year, so On this day shows three and links the fourth.
    for words in ["Ice on the lake \(mark) #ice-\(mark)", "Skating one \(mark)", "Skating two \(mark)", "Skating three \(mark)"] {
      made.append(try await Self.addNoteNamed(words, on: "\(year - 1)\(monthDay)", server: server, token: reader))
    }
    made.append(try await Self.addNoteNamed("The first snow \(mark)", on: "\(year - 3)\(monthDay)", server: server, token: reader))
    let server = server, gone = made
    addTeardownBlock {
      for note in gone { try await Self.deleteNote(note, server: server, token: reader) }
      try await Self.revoke(reader, server: server)
    }

    let app = launch(as: reader, more: ["CHANGELOG_LOCK_ANSWER": "yes"])
    let row = { (words: String) in
      app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", words)).firstMatch
    }
    hideKeyboard(app)
    app.tabBars.buttons["Notes"].tap()
    let list = app.collectionViews.firstMatch
    let ago = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'A year ago you were'")).firstMatch
    expect(list, "Notes reads", in: app, timeout: 30)
    for _ in 0..<8 where !(ago.exists && ago.isHittable) { list.swipeUp(velocity: .slow) }
    expect(ago, "On this day heads last year", in: app, timeout: 15)
    let fourth = app.buttons["One more note"]
    for _ in 0..<4 where !(fourth.exists && fourth.isHittable) { list.swipeUp(velocity: .slow) }
    expect(fourth, "the day's other note is a link away", in: app)
    let snowRow = row("The first snow \(mark)")
    expect(snowRow, "the year before that has its note", in: app)
    expect(app.buttons.matching(NSPredicate(format: "label BEGINSWITH '3 years ago you were'")).firstMatch,
           "and its own head", in: app)
    // The four were written in the same minute, so which three come first is the server's to say.
    let lastYears = app.buttons.matching(NSPredicate(format: "label CONTAINS %@ AND NOT label CONTAINS 'first snow'", mark))
    XCTAssertEqual(lastYears.count, 3, "On this day shows a day's first three")
    keep(app, "On this day")
    fourth.tap()
    expect(row("Ice on the lake \(mark)"), "the day's own page has every note", in: app)
    expect(row("Skating three \(mark)"), "every one", in: app)
    app.navigationBars.buttons.firstMatch.tap()

    // Words, across every year, newest first.
    let box = app.textFields["search"]
    for _ in 0..<8 where !(box.exists && box.isHittable) { list.swipeDown(velocity: .fast) }
    box.tap()
    box.typeText("\(mark)\n")
    let sentence = app.staticTexts["search-found"]
    expect(sentence, "the search answers", in: app, timeout: 15)
    XCTAssertEqual(sentence.label, "5 notes for “\(mark)”, newest first")
    XCTAssertFalse(app.keyboards.firstMatch.exists, "searching puts the keyboard away")
    let snow = row("The first snow \(mark)")
    for _ in 0..<4 where !(snow.exists && snow.isHittable) { list.swipeUp(velocity: .slow) }
    expect(snow, "a note from three years ago is found", in: app)
    keep(app, "Search")
    snow.tap()
    expect(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "The first snow \(mark)")).firstMatch,
           "a found note opens", in: app)
    app.navigationBars.buttons.firstMatch.tap()

    // A tag alone is that tag's notes.
    expect(app.buttons["Clear"], "a search can be cleared", in: app)
    app.buttons["Clear"].tap()
    box.tap()
    box.typeText("#ice-\(mark)\n")
    expect(sentence, "the tag search answers", in: app, timeout: 15)
    XCTAssertEqual(sentence.label, "1 note for “#ice-\(mark)”, newest first")
    expect(row("Ice on the lake \(mark)"), "the tagged note is found", in: app)

    // Nothing found says so; Clear goes back to the days.
    app.buttons["Clear"].tap()
    box.tap()
    box.typeText("nothing\(mark)here \(mark)\n")
    expect(sentence, "a search that finds nothing answers", in: app, timeout: 15)
    XCTAssertEqual(sentence.label, "No notes have all of those words.")
    keep(app, "Nothing found")
    app.buttons["Clear"].tap()
    XCTAssertTrue(sentence.waitForNonExistence(timeout: 10), "Clear ends the search")
    expect(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Today'")).firstMatch, "the days are back", in: app)
    app.terminate()
  }

  /// Settings' lock switch, on or off, and it says so.
  @MainActor private func turnLock(in app: XCUIApplication, on: Bool) {
    hideKeyboard(app)
    app.tabBars.buttons["Settings"].tap()
    let lock = app.switches["Lock reading"]
    // Slowly: a quick swipe can carry the row past without stopping on it.
    for _ in 0..<12 where !(lock.exists && lock.isHittable) { app.collectionViews.firstMatch.swipeUp(velocity: .slow) }
    keep(app, on ? "The lock, off" : "The lock, on")
    XCTAssertTrue(lock.isHittable, "Settings offers the lock")
    // The row is the element; its switch is at the right-hand end.
    lock.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
    let said = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", on ? "1" : "0"), object: lock)
    XCTAssertEqual(XCTWaiter().wait(for: [said], timeout: 10), .completed, "the lock turned")
  }

  // MARK: Helpers

  /// The app signed in to the dev server: its own account, or another
  /// account's token; with a moment to pick, for the Moments test.
  private func launch(as other: String? = nil, moment: Bool = false, more: [String: String] = [:]) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchEnvironment["CHANGELOG_DEV_TOKEN"] = other ?? token
    app.launchEnvironment["CHANGELOG_DEV_URL"] = server
    if moment { app.launchEnvironment["CHANGELOG_MOMENT"] = "1" }
    for (key, value) in more { app.launchEnvironment[key] = value }
    app.launch()
    expect(app.buttons["Commit"], "signed in to the dev server", in: app, timeout: 30)
    return app
  }

  /// iOS says the icon changed, in Springboard's alert.
  @MainActor private func okIconAlert() {
    let ok = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.buttons["OK"]
    if ok.waitForExistence(timeout: 10) { ok.tap() }
  }

  @MainActor private func keep(_ app: XCUIApplication, _ name: String) {
    let shot = XCTAttachment(screenshot: app.screenshot())
    shot.name = name
    shot.lifetime = .keepAlways
    add(shot)
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

  /// A token on the dev server's own fictional account, with the sandbox
  /// token's scopes left as they are: it can't read, and Quinn's branches
  /// count on that.
  private static func tokenOnThisAccount(_ scopes: [String], server: String) async throws -> String {
    let email = "ada@example.com"
    _ = try await web("POST", "/api/auth/start", ["email": email], server: server)
    let (mail, _) = try await web("GET", "/dev-mail/?to=\(email)", nil, server: server)
    let page = String(decoding: mail, as: UTF8.self)
    let code = try XCTUnwrap(page.range(of: "code where you asked: [0-9]+", options: .regularExpression)
      .flatMap { page[$0].split(separator: " ").last.map(String.init) }, "the dev mailbox has the code")
    let (_, verified) = try await web("POST", "/api/auth/verify", ["email": email, "code": code], server: server)
    let set = verified.value(forHTTPHeaderField: "Set-Cookie") ?? ""
    let cookie = try XCTUnwrap(set.range(of: "__Host-rn=[^;, ]+", options: .regularExpression).map { String(set[$0]) },
                               "signed in on the web")
    // A name a live token already has is refused.
    let name = "Changelog \(UUID().uuidString.prefix(6))"
    let (made, _) = try await web("POST", "/api/tokens", ["name": name, "scopes": scopes, "expiry": "never"],
                                  cookie: cookie, server: server)
    struct Made: Decodable { let token: String }
    return try JSONDecoder().decode(Made.self, from: made).token
  }

  /// A note from another channel, through the sandbox token.
  /// One write to `/v1`, which has to land.
  @discardableResult
  private static func send(_ method: String, _ path: String, _ body: [String: Any], server: String, token: String) async throws -> Data {
    var request = URLRequest(url: URL(string: server + path)!)
    request.httpMethod = method
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(UUID().uuidString.lowercased(), forHTTPHeaderField: "Idempotency-Key")
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
    XCTAssertTrue((200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0), String(decoding: data, as: UTF8.self))
    return data
  }

  private static func addNote(_ words: String, markup: String? = nil, server: String, token: String) async throws {
    var request = URLRequest(url: URL(string: "\(server)/v1/notes")!)
    request.httpMethod = "POST"
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(UUID().uuidString.lowercased(), forHTTPHeaderField: "Idempotency-Key")
    var body = ["text": words]
    if let markup { body["markup"] = markup }
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    let (_, response) = try await URLSession(configuration: .ephemeral).data(for: request)
    XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 201, "the note went in")
  }

  /// A note added for a test, with where to find it again.
  private static func addNoteNamed(_ words: String, on date: String? = nil, server: String,
                                   token: String) async throws -> (date: String, id: String) {
    var request = URLRequest(url: URL(string: "\(server)/v1/notes")!)
    request.httpMethod = "POST"
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(UUID().uuidString.lowercased(), forHTTPHeaderField: "Idempotency-Key")
    var body = ["text": words]
    if let date { body["date"] = date }
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
    XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 201, "the note went in")
    let receipt = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let note = try XCTUnwrap(receipt["note"] as? [String: Any])
    return (try XCTUnwrap(note["date"] as? String), try XCTUnwrap(note["id"] as? String))
  }

  /// How many files a note has on the dev server.
  private static func noteFiles(_ note: (date: String, id: String), server: String, token: String) async throws -> Int {
    var request = URLRequest(url: URL(string: "\(server)/v1/notes/\(note.date)/\(note.id)")!)
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    let (data, _) = try await URLSession(configuration: .ephemeral).data(for: request)
    let read = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    return (read["media"] as? [Any])?.count ?? (read["files"] as? Int) ?? 0
  }

  /// Waits for a note to have so many files, as a queued change lands.
  @MainActor private func expectFiles(_ count: Int, on note: (date: String, id: String), _ what: String,
                           file: StaticString = #filePath, line: UInt = #line) async throws {
    var now = -1
    for _ in 0..<40 {
      now = try await Self.noteFiles(note, server: server, token: token)
      if now == count { return }
      try await Task.sleep(for: .milliseconds(500))
    }
    XCTFail("Expected: \(what) (it has \(now))", file: file, line: line)
  }

  private static func deleteNote(_ note: (date: String, id: String), server: String, token: String) async throws {
    var request = URLRequest(url: URL(string: "\(server)/v1/notes/\(note.date)/\(note.id)")!)
    request.httpMethod = "DELETE"
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue(UUID().uuidString.lowercased(), forHTTPHeaderField: "Idempotency-Key")
    let (_, response) = try await URLSession(configuration: .ephemeral).data(for: request)
    XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 204, "the note went")
  }

  /// One Upcoming event on the fictional account, on the batch `/v1` takes.
  private static func upcomingBatch(_ body: [String: Any], server: String, token: String) async throws -> Data {
    var request = URLRequest(url: URL(string: "\(server)/v1/upcoming/batch")!)
    request.httpMethod = "POST"
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(UUID().uuidString.lowercased(), forHTTPHeaderField: "Idempotency-Key")
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
    XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200, String(decoding: data, as: UTF8.self))
    return data
  }

  private static func addDate(_ title: String, on date: String, server: String, token: String) async throws -> (id: String, revision: Int) {
    _ = try await upcomingBatch(["add": [["kind": "event", "title": title, "date": date]]], server: server, token: token)
    var request = URLRequest(url: URL(string: "\(server)/v1/upcoming")!)
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    let (data, _) = try await URLSession(configuration: .ephemeral).data(for: request)
    let list = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let entries = try XCTUnwrap(list["entries"] as? [[String: Any]])
    let entry = try XCTUnwrap(entries.first { $0["title"] as? String == title })
    return (try XCTUnwrap(entry["id"] as? String), try XCTUnwrap(entry["revision"] as? Int))
  }

  private static func removeDate(_ id: String, revision: Int, server: String, token: String) async throws {
    _ = try await upcomingBatch(["remove": [["id": id, "revision": revision]]], server: server, token: token)
  }

  private static func statusOfMe(server: String, token: String) async throws -> (Int, Data) {
    var request = URLRequest(url: URL(string: "\(server)/v1/me")!)
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
    return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
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

  /// Every check-in on the dev server's account, so a test starts clear.
  private static func deleteCheckIns(server: String, token: String) async throws {
    struct Stays: Decodable { struct Stay: Decodable { let id: String }; let items: [Stay] }
    var list = URLRequest(url: URL(string: "\(server)/v1/check-ins?limit=100")!)
    list.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    let (data, _) = try await URLSession.shared.data(for: list)
    for stay in try JSONDecoder().decode(Stays.self, from: data).items {
      var delete = URLRequest(url: URL(string: "\(server)/v1/check-ins/\(stay.id)")!)
      delete.httpMethod = "DELETE"
      delete.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
      delete.setValue(UUID().uuidString, forHTTPHeaderField: "Idempotency-Key")
      _ = try await URLSession.shared.data(for: delete)
    }
  }

  /// Every remembered place, for a token that may read and change all notes.
  private static func forgetPlaces(server: String, token: String) async throws {
    struct Places: Decodable { struct Place: Decodable { let id: String }; let places: [Place] }
    var list = URLRequest(url: URL(string: "\(server)/v1/check-ins/places")!)
    list.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    let (data, _) = try await URLSession.shared.data(for: list)
    for place in try JSONDecoder().decode(Places.self, from: data).places {
      var forget = URLRequest(url: URL(string: "\(server)/v1/check-ins/places/\(place.id)")!)
      forget.httpMethod = "DELETE"
      forget.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
      forget.setValue(UUID().uuidString, forHTTPHeaderField: "Idempotency-Key")
      _ = try await URLSession.shared.data(for: forget)
    }
  }

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
