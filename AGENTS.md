# Changelog for iPhone

Changelog is a fast way to send notes into Release Notes
(`jthingelstad/yvn-release-notes`). It talks only to Release Notes' public
`/v1` API, designed in that repo's `docs/API.md`. That document is the
contract: when the app needs something the API doesn't do, change the design
there first, never work around it here.

`CLAUDE.md` is a symlink to this file. Do not fork them.

## Layout

- `ChangelogKit/` is a Swift package with everything that isn't a screen:
  `APIClient` (every `/v1` call, typed errors), `Outbox` (the offline queue),
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
  read back for Log), `QuickNote` (a note sent from outside the app's screens,
  within a deadline, else left for the app), `Moment` (a moment picked in
  Apple's Journaling Suggestions, as plain values, and what it puts in the
  draft), `NoteMoment` (those values as `/v1` keeps them beside the words)
  and `WidgetSnapshot` (what the widgets show, one day per local
  midnight). It has its own tests:
  `swift test --package-path ChangelogKit`.
- `Changelog/` is the SwiftUI app: `AppModel` holds the state, `Views/` the
  screens (Log, Upcoming, Activity, Settings, sign-in: Release Notes'
  page in a sign-in sheet on Safari's shared session, or a pasted token),
  `Locator` one location fix, `Recorder` a voice memo, `PhoneReminders`
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
- `Shared/` is built into both the app and the widget extension:
  `AppRoute` (the tab or the new note the app opens to) and `NewNoteIntent`
  ("New Note", which opens Log ready to write; a control can only name an
  intent both targets have).
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
  it: "No leave it"). The app mirrors the server and the sticky tag into the
  group's defaults. Only a debug build reads a saved server: a release
  build, and the share extension and Siri in one, always use Release Notes
  itself (`APIClient.production`).
- `Widgets/` is the widget extension: Today (small and medium on the Home
  Screen, three on the Lock Screen) and the New Note control (Control
  Center, the Lock Screen, the Action Button). A widget never calls the
  API: it reads the `WidgetSnapshot` the app writes to the group's
  defaults each time it reads `/v1/me`, and has one entry a day from the
  server's `days`. A tap opens `com.yourversionnumber.changelog:new-note`.
- `Changelog.xcodeproj` uses synchronized folders, so new files in
  `Changelog/`, `Shared/`, `ShareExtension/` and `Widgets/` need no
  project edit.
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
  never makes a second note. Upcoming's saves and deletes are the one
  exception: they go at once, since each is made from a revision and a
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
- A note's files are posted and its place named, and both saved, before
  the note is sent (the Outbox's `prepare`), so a resend is the same
  request. The token never goes to the storage form.
- Location is When In Use, one fix when the owner asks (or has "Add where
  I am" on), never in the background. Each Here is a lookup Release Notes
  pays for, capped at 100 a day: ask once a draft, never as words change.
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
- A moment's pieces also go as values beside the words (`moment` on
  `POST /v1/notes`, API 1.5.0; `docs/MOMENTS.md` in the Release Notes
  repo), tidied as Release Notes keeps them: each piece with the line it
  wrote, and at Commit only those whose line is still in the words, so a
  line deleted takes its piece with it. The words stay the note. They are
  queued in the note's `NotePost` and resent with it under its key. A
  Release Notes that won't take them (`invalid_request` at `moment`, as
  one before 1.5.0 answers, or at one of its pieces) gets the words
  alone, once, under a new key. A new kind goes to Release Notes first, in
  a new API version, before the app sends it.
- The app reads back only notes this token wrote, and the activity log
  (which has no words in it). It never asks for `notes:read`. Log's Today
  shows the words of today's notes this token wrote (Jamie, 2026-10-29:
  "just add the API calls to read what was sent"), read back by id on
  each refresh (`TodayWords`) and held in memory only: never on disk, in
  the App Group, a widget, a notification or what Siri says.
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
Upcoming (a date added and deleted), Activity and Settings, and a share
from Photos against the dev server, checking `/v1/activity` that each made
exactly one note (and `/v1/upcoming` the date). Name tests after
the simulator to run only those. A simulator records with the Mac's
microphone, which can fail to answer; the voice memo test skips then.

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
