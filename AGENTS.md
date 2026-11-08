# Changelog for iPhone

Changelog is a fast way to send notes into Release Notes
(`jthingelstad/yvn-release-notes`). It talks only to Release Notes' public
`/v1` API, designed in that repo's `docs/API.md`. That document is the
contract: when the app needs something the API doesn't do, change the design
there first, never work around it here.

`CLAUDE.md` is a symlink to this file. Do not fork them.

## Layout

- `ChangelogKit/` is a Swift package with everything that isn't a screen:
  `APIClient` (every `/v1` call, typed errors), `Outbox` (the offline queue,
  each write with the account it was written under), `CheckIns` (reports, the
  check-in calls and the words a stay is said in),
  `Media` (uploads, the types Release Notes keeps, the storage form),
  `Hashtags` (a port of Release Notes' `packages/domain/tags.ts`; keep them
  in step), `TokenStore` (the Keychain), `SignIn` (signing in with
  Release Notes: OAuth with PKCE for the app's own scheme, registered
  afresh each time, the code spent once for an ordinary API token; no
  refresh token), `Shares` (the App Group and the extension's hand-off to
  the app), `Upcoming` (the dates and their batch), `NotificationPlan`
  (Upcoming reminders and the daily prompt, within iOS's 64 waiting
  notifications), `ActivityNotices` (which activity rows tell the phone
  something), `TodayWords` (the words of today's notes this token wrote,
  read back for Log by a token that can't read the rest), `Rich` (a rich note's
  words as blocks, a port of Release Notes' `packages/domain/rich.ts`; keep them
  in step), `TokenSwitch` (trading a token for one that may read, without
  signing out), `QuickNote` (a note sent from outside the app's screens,
  within a deadline, else left for the app), `Moment` (a moment picked in
  Apple's Journaling Suggestions, as plain values, and what it puts in the
  draft) and `WidgetSnapshot` (what the widgets show, one day per local
  midnight). It has its own tests:
  `swift test --package-path ChangelogKit`.
- `Changelog/` is the SwiftUI app: `AppModel` holds the state, `Views/` the
  screens (Log, Upcoming, Activity, Settings, sign-in: Release Notes'
  page in a sign-in sheet on Safari's shared session, or a pasted token),
  `Locator` one location fix, `CheckInRecorder` the Check-ins switch and iOS's
  Visits service, `Recorder` a voice memo, `PhoneReminders`
  the phone's own notifications (there is no push server: they are
  scheduled ahead, or found by background refresh), `Intents` Shortcuts'
  and Siri's "Add a Note" (sent as a share is, without opening the app,
  within 5 seconds, well inside Siri's own wait, else left for the app;
  Jamie, 2026-10-30) and the phrases Siri knows, `Moments` the
  Journaling Suggestions picker's moment read into `Moment`. That
  framework is in the phone's SDK only, so `Moments` and Log's Moments
  button are inside `#if canImport(JournalingSuggestions)`; a simulator's
  debug build has a fictional stand-in moment instead, behind
  `CHANGELOG_MOMENT`, for the test cycle. The picker needs the
  `com.apple.developer.journal.allow` entitlement, the array
  `suggestions` as the App ID's profile grants it (`true` doesn't sign),
  and the capability on the App ID, and asks no permission.
- `Theme/` is built into the app, the share extension and the widgets:
  Release Notes' look, from its web app (`web/src/styles/site.css`). Type
  on paper: its colours light and dark, Bricolage Grotesque and Martian
  Mono (`Theme/Fonts/`, OFL, named in each target's Info.plist under
  `UIAppFonts`) at the size Dynamic Type asks for (`.face(_:)`), the
  tangerine Commit, forms flat on the paper (`paperForm()`,
  `paperRows()`) and the rest. Every screen, sheet and widget is on the
  paper (Jamie, 2026-10-30: align the app with the website); the tab bar,
  menus, swipe actions and the Lock Screen stay as iOS draws them. A
  colour or a size changes on the web first, then here.
- `Shared/` is built into both the app and the widget extension:
  `AppRoute` (the tab, the new note or the check-in the app opens to),
  `NewNoteIntent` ("New Note", which opens Log ready to write) and
  `CheckInIntent` ("Check In", which opens Activity and checks in). A control
  can only name an intent both targets have.
- `ShareExtension/` is the share sheet's Changelog. It keeps each share in
  a queue of its own in the App Group's `shares/` folder, sends it if it
  can within 25 seconds, and leaves the rest for the app, which adopts it
  into its Outbox under the same key. It has about 120 MB of memory: files
  are copied and streamed from disk, never read whole, except photos. A
  very large photo (ProRAW, 48 MP) may not fit; it is kept as it is, not
  shrunk (Jamie, 2026-10-30, asked: "Leave").
- The token is in the Keychain under the App Group's access group, so the
  extension can read it; a token kept by an earlier build moves there when
  the app starts. It outlives deleting the app, as Keychain items do, so a
  reinstall is still signed in (Jamie, 2026-10-30, asked whether to clear
  it: "No leave it"). The app mirrors the server, the sticky tag and the
  account into the group's defaults. Only a debug build reads a saved
  server: a release build, and the share extension and Siri in one, always
  use Release Notes itself (`APIClient.production`).
- `Widgets/` is the widget extension: Today (small and medium on the Home
  Screen, three on the Lock Screen) and the New Note and Check In controls
  (Control Center, the Lock Screen, the Action Button). A widget never calls the
  API: it reads the `WidgetSnapshot` the app writes to the group's
  defaults each time it reads `/v1/me`, and has one entry a day from the
  server's `days`. A tap opens `com.yourversionnumber.changelog:new-note`.
- `Changelog.xcodeproj` uses synchronized folders, so new files in
  `Changelog/`, `Shared/`, `Theme/`, `ShareExtension/` and `Widgets/` need
  no project edit.
- Versions count from Changelog's start on 2026-10-29 by Your Version
  Number's arithmetic (decades.years.days, the day in Chicago), like
  Release Notes' own. `scripts/version.sh` stamps each target's built
  Info.plist (a build phase; script sandboxing is off for it): the
  version, Apple's build number (the commit count, since it must be whole
  numbers) and the commit, which Settings shows as the build
  (`Build.swift`). Never set `MARKETING_VERSION` by hand.
  `scripts/version.sh test` checks the arithmetic, in CI.

## Rules

- This repo is public. Never commit real notes, real versions, real
  account details, tokens, screenshots of a real account, or Apple account
  or signing details. Examples use the dev server's fictional account.
  The signing team lives in `Config/Signing.local.xcconfig`, which git
  ignores; never set `DEVELOPMENT_TEAM` in the project.
- Never test against production. Run the Release Notes dev server
  (`tools/dev-server.ts`, port 8790) and point a debug build at it. No
  agent, script or test writes to a real account. The one pass on
  production is by hand: the owner of an account trying a TestFlight
  build on it (`docs/PHONE-TEST.md`), since a release build talks to
  nothing else.
- No third-party packages. Apple's frameworks only.
- Never log, print or put in an error message a token or a note's text.
- A file URL goes to `FileManager` as `path(percentEncoded: false)`.
  `path()` escapes the space in "Application Support", where the queue's
  files are, and the file is then never found. Tests keep files in folders
  with a space for this.
- Every write goes through the Outbox with its idempotency key, so a resend
  never makes a second note. Upcoming's saves and deletes, and a check-in's
  name, its deleting and remembered places, are the exceptions (a check-in's
  report and a tap queue as usual): they go at once, since each is made from a revision and a
  refusal (a city the search doesn't know) is for the person to fix there
  and then. Each still carries an Idempotency-Key held for as long as the
  same request is tried again (`RequestKey`).
- A notification never carries a note's words, and nor does a widget or
  what Siri or a shortcut says back. On widgets, Upcoming's titles show on
  the Home Screen only, never the Lock Screen. A reminder notification
  carries its date's title, as the email's line does, Lock Screen included
  (Jamie, 2026-10-30, asked whether to hide them there: "No"). A widget
  never works out a version: each day's is the server's, from `/v1/me`'s
  `days`. Activity notices never tell of this token's own rows or the
  daily email.
- Every write waiting in the Outbox knows the account it was written
  under (`/v1/me`'s `account`, API 1.4.0): the app's own, and the share
  extension's and Siri's, stamped from the account the app mirrors into the
  App Group at each read of `/v1/me` (kept after signing out, so a share
  made then is the last account's). A write of another account, or of none
  known, is held, never sent, until the owner chooses on Log (Jamie,
  2026-10-30): "Send to this account" (the same key, its files posted again,
  since uploads are each account's; its place stays, being only names) or
  Delete, which asks first. An edit or a delete of another account's note
  can only be deleted. Signing back in to its own account sends it as
  before. Writes an earlier build queued carry no account: the first read
  of `/v1/me` by the token still signed in stamps them with its account.
- Today's "mine" (words read back, Edit and Delete) is the activity row's
  `token_id` against `/v1/me`'s `token.id`; the token's name decides only
  for a row from before API 1.4.0, which has no `token_id`.
- A note's files are posted and its place named, and both saved, before
  the note is sent (the Outbox's `prepare`), so a resend is the same
  request. The token never goes to the storage form.
- An edit changes a note's words and files together (`NoteChange`), queued
  all or none: new words first (`PUT`), then files off (`DELETE
  /v1/notes/{date}/{id}/media/{n}`), then files on (`.attach`, `POST …/media`
  with uploads posted first, as a new note's). That order keeps every step
  one Release Notes takes: an edit can't take a note's words away, a note
  holds at most 20 files, and one with no words keeps its last, so for that
  note one new file goes on, then its last file comes off, then the rest
  go on. The steps share a `group`: each goes only once those before it
  have, so a refused step (the note changed elsewhere) holds the rest,
  across relaunches, until it is fixed, and discarding it discards them. A
  file already gone is done, not refused. Taking a file off asks first; a file
  that came by email stays in that email. New files an edit never saved
  leave the phone with the sheet.
- Location is When In Use, one fix when the owner asks (Here, Check in now, the
  Check In control, or "Add where I am" on). Each Here is a lookup Release Notes pays for, capped at
  100 a day: ask once a draft, never as words change. A check-in's page asks
  only when Name opens or Write about this is tapped.
- Check-ins (`CheckInRecorder`, `docs/CHECK-INS.md` in the Release Notes repo)
  are the one thing that uses Always and iOS's Visits service, and only once
  their Settings switch is turned on: it is off until then. Each stop goes to
  the Outbox under its own key, so a bad connection loses nothing. iOS can
  start the app to deliver one, with no window, before the phone's first
  unlock, when defaults read empty: never stop monitoring because of that, hold
  in memory what can't be queued yet, and only drop it once off really means off.
  Rows, a check-in's page and the map of them open with reading locked (Jamie's
  call); capture is never locked. The privacy page says this, and the written
  reason for Always that Beta App Review reads is in `docs/DISTRIBUTION.md`.
- The visits test's file (`VisitsTest`) stays read-only, for the owner to read,
  share and delete, until Jamie decides what happens to it. Nothing writes to
  it and nothing in it goes to Release Notes. It goes when signing out, as the
  test promised; check-ins stay on the account.
- A moment only fills the draft: nothing is sent until the person
  commits. Its photos go through `addPhoto` within the draft's room, its
  place through the same Here naming as the location button, once a pick,
  and every other kind becomes one plain line by `Moment`'s rules, in the
  person's units, never by a model. Videos are left out, with a line the
  person sees, not in the note. A moment from an earlier day files to it
  (`/v1`'s `date`), shown under the box with "File to today"; the version
  shows only if the app already has it, else the date. A later day files
  to today, and a day Release Notes refuses (`date_out_of_range`, before
  the birthday, which the app never learns) is filed to the day it was
  written by the Outbox, once, under a new key.
- Changelog is "the fast way in, with your notes along; account and settings
  stay on the web" (Jamie, 2026-11-05). It reads days, notes and their files,
  searches every note as the web does (all the words, or one `#tag` alone for
  that tag's notes) and shows On this day under Today, a day's first three
  notes with the rest on its page; a list of tags and releases come next, the one map is of check-ins
  (Jamie's word, 2026-11-06, phase 4 of `docs/CHECK-INS.md` in Release Notes), a
  map of notes only on Jamie's word, badges and the mail log stay on the web. A new sign-in asks for `notes:all`
  (Jamie, 2026-10-30), which anyone may untick on the consent page; a token
  from before it, or one with it unticked, still captures, and reads back only
  the notes it wrote, by id, for Log's Today (`TodayWords`). The Notes tab's
  one button is the only way to upgrade: no pop-up anywhere else, and the
  switches, the queue and the draft stay.
- A note's words and files are held in memory only: never on disk, in the App
  Group, a widget, a notification or what Siri says. The JSON comes `no-store`.
  Files come through an ephemeral session; a file open in Quick Look sits in
  `tmp/previews/` until the preview closes, the lock closes or the app starts.
  `forget()` clears all of it.
- The Face ID lock is on reading, never on capture: Log, Share and Siri write
  whether it is locked or not, off until turned on. Locked, Today reads only
  this token's notes, so Log shows what it always did, a waiting edit shows no
  words, and Fix opens only on this token's own note. Turning it on or off asks
  first. Activity's rows open their notes only while reading is open, and
  close with it; the rows themselves never carry a note's words.
- iOS 26 and later, iPhone only, Swift 6 strict concurrency.
- No task groups (`withTaskGroup` and its kin). Built with Swift 6.4
  (Xcode 27.1) and optimized, as TestFlight builds are, the one in
  `TodayWords` ended before its children finished, and build 53 crashed
  on launch (2026-10-30); Debug, and so every test then, never did. Run
  work side by side as one `Task` each, awaited in turn, as `TodayWords`
  does, and keep ChangelogKit's tests passing optimized too.
- What each version brought is "Release Notes for Changelog" on Release
  Notes' public site (`/guide/changelog/`, `site/guide/changelog.md` in
  the Release Notes repo; Jamie, 2026-10-29: "Please make sure that there
  is a changelog page for changelog itself on the public site."). When a
  build that changes what someone using the app sees goes to TestFlight,
  its lines go there, in a PR in that repo, under Changelog's version for
  that day: what you can do now, in that page's voice, never internal
  work. A build of docs or CI alone adds nothing.
- Codex reviews every PR (`chatgpt-codex-connector[bot]`). Read its
  findings and fix or answer each before calling the work done.

## Icons

The app icons come from the 2026-11-01 icon study in
`docs/design/icon-study-2026-11-01/`: "Versions", three folded v marks on ink
navy (`AppIcon`), and four Supporting Member editions (`AppIcon-Paper`,
`-Copper`, `-Terminal`, `-Afterglow`, named in
`ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES`). `sh scripts/make_icons.sh`
rebuilds the sets from the study, with a small `<set>-Preview` image beside
each for Settings, and the in-app mark. Release Notes' icon is the single
folded v with a period on cobalt; the two must stay distinct side by side.

The mark beside "Changelog" (the bar atop each tab, the sign-in screen, the
widgets) is Versions too: `BrandMark` in `Theme/Theme.swift` draws
`Theme/Brand.xcassets`' `BrandMark` as a rounded tile, in the app, its
widgets and its share extension alike. It replaced the drawn Release Notes
mark (a v, a dot and two lines) on 2026-11-01, when Jamie found the old logo
still inside the app. It stays Versions whichever icon a member chose.

Settings, "App icon" (`Changelog/Views/AppIconSection.swift`, the list in
ChangelogKit's `AppIcon`) offers the five to Supporting Members of the
Weekly Thing: `/v1/me`'s `supporting_member` (API 1.12.0), which Release
Notes gives its administrator too (Jamie, 2026-11-01: "Approved: Changelog
member icons unlock for Supporting Members", knowing App Review guideline
3.1.1 limits unlocking a feature for an outside membership). Anyone else
sees no section and no word of membership, and the app never links to
joining. A lapsed member keeps the icon they chose, with only it and
Versions offered: iOS shows an alert whenever the icon changes, so it
changes only on a tap.

## Building

```sh
swift test --package-path ChangelogKit
swift test -c release -Xswiftc -enable-testing --package-path ChangelogKit
xcodebuild -project Changelog.xcodeproj -scheme Changelog \
  -destination 'platform=iOS Simulator,name=iPhone 17' build
```

CI (`.github/workflows/test.yml`) runs them on every PR: the tests in
Debug and optimized, since a TestFlight build is optimized. Actions are pinned
by commit SHA.

`DevServerTests` runs the client against the real `/v1` and skips unless a
dev server token is set. Start the Release Notes dev server
(`node --import tsx tools/dev-server.ts` in that repo, Node 24); it prints
a token for its fictional account. Then:

```sh
CHANGELOG_DEV_TOKEN=rn_... swift test --package-path ChangelogKit --filter DevServerTests
```

It runs only against localhost, never production, because it writes.
`CHANGELOG_DEV_URL` (say `http://localhost:8792`) picks another port, for
the tests and for a debug build launched with
`SIMCTL_CHILD_CHANGELOG_DEV_URL`. Start the dev server with `--fake-places`
for Here. A simulator build that signs in needs ad-hoc signing
(`CODE_SIGN_IDENTITY=-`): `CODE_SIGNING_ALLOWED=NO` leaves out the
Keychain.

`scripts/ui-test-cycle.sh` (`ChangelogUITests`) is the test cycle: it
builds ad-hoc signed, grants photos, location and the microphone, sets the
simulator in Minneapolis, and drives a note, a photo, Here, a moment (the
stand-in, filed to its day and then to today), a voice memo,
Upcoming (a date added and deleted, and dates under their months with
how far off they are), Activity and Settings, the app icons
(chosen and put back), and a share
from Photos against the dev server, checking `/v1/activity` that each made
exactly one note (and `/v1/upcoming` the date); and a note held for
another account, a new fictional one it makes on the dev server's web API,
sent and deleted. Name tests after the simulator to run only those. A
simulator records with the Mac's microphone, which can fail to answer; the
voice memo test skips then.

`scripts/testflight.sh` uploads a clean commit on main to TestFlight, for
internal testers only (`Config/ExportOptions-TestFlight.plist`; Xcode
leaves the build number alone). An upload goes to Apple and to Jamie's
phone, and to every tester's. Every upload, internal ones included, is
Jamie's call each time (Jamie, 2026-10-30: "We are pushing to TestFlight
too much. We are still in active dev and folks are getting pushed releases
a lot right now. For now let's only push to test flight when I say go.
Feel free to ask."; it ended the standing go for internal builds of
2026-10-29). So merge as usual, then ask before uploading: one ask can
cover several merges. A merge of docs or CI alone needs no build.
`--external` makes the build outside testers can get, and
`scripts/asc.swift` makes the App Store Connect calls Xcode doesn't (test
information, the review sign-in, groups), with the same key; both are in
`docs/DISTRIBUTION.md`. `testflight.sh` needs
one phone registered to the team (automatic signing archives with a
development profile, which Apple makes only for a team with a device), and
either an App Store Connect API key, which works from any shell (an Admin
team key, its ids in `Config/AppStoreConnect.local`, which git ignores; the
script says how), or Xcode's sign-in, which a background process can't
reach (run it from Terminal: an agent `open`s a `.command` file). The key,
its ids and the team never go in this repo. Each target has a `PrivacyInfo.xcprivacy` naming why it uses Apple's required-reason APIs
(defaults, file dates); a new use of one of those goes there too, or App
Store Connect refuses the build. `ITSAppUsesNonExemptEncryption` is false:
the app's only encryption is HTTPS. `docs/PHONE-TEST.md` is the pass by
hand each build gets on a real phone (and an Android version's list of
what it must do); `docs/DISTRIBUTION.md` is the way to outside testers and
the App Store, each step Jamie's call.
