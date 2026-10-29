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
  in step), `TokenStore` (the Keychain), `Shares` (the App Group and the
  extension's hand-off to the app), `Upcoming` (the dates and their
  batch), `NotificationPlan` (Upcoming reminders and the daily prompt,
  within iOS's 64 waiting notifications) and `ActivityNotices` (which
  activity rows tell the phone something). It has its own tests:
  `swift test --package-path ChangelogKit`.
- `Changelog/` is the SwiftUI app: `AppModel` holds the state, `Views/` the
  screens (Log, Upcoming, Activity, Settings, sign-in), `Locator` one
  location fix, `Recorder` a voice memo, `PhoneReminders` the phone's own
  notifications (there is no push server: they are scheduled ahead, or
  found by background refresh).
- `ShareExtension/` is the share sheet's Changelog. It keeps each share in
  a queue of its own in the App Group's `shares/` folder, sends it if it
  can within 25 seconds, and leaves the rest for the app, which adopts it
  into its Outbox under the same key. It has about 120 MB of memory: files
  are copied and streamed from disk, never read whole, except photos.
- The token is in the Keychain under the App Group's access group, so the
  extension can read it; a token kept by an earlier build moves there when
  the app starts. The app mirrors the server and the sticky tag into the
  group's defaults.
- `Changelog.xcodeproj` uses synchronized folders, so new files in
  `Changelog/` and `ShareExtension/` need no project edit.
- Versions count from Changelog's start on 2026-10-29 by Your Version
  Number's arithmetic (decades.years.days, the day in Chicago), like
  Release Notes' own. `scripts/version.sh` stamps both targets' built
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
  (`tools/dev-server.ts`, port 8790) and point a debug build at it.
- No third-party packages. Apple's frameworks only.
- Never log, print or put in an error message a token or a note's text.
- Every write goes through the Outbox with its idempotency key, so a resend
  never makes a second note. Upcoming's saves and deletes are the one
  exception: they go at once, since each is made from a revision and a
  refusal (a city the search doesn't know) is for the person to fix there
  and then. Each still carries an Idempotency-Key held for as long as the
  same request is tried again (`RequestKey`).
- A notification never carries a note's words. Activity notices never tell
  of this token's own rows or the daily email.
- A note's files are posted and its place named, and both saved, before
  the note is sent (the Outbox's `prepare`), so a resend is the same
  request. The token never goes to the storage form.
- Location is When In Use, one fix when the owner asks (or has "Add where
  I am" on), never in the background. Each Here is a lookup Release Notes
  pays for, capped at 100 a day: ask once a draft, never as words change.
- The app reads back only notes this token wrote, and the activity log
  (which has no words in it). It never asks for `notes:read`.
- iOS 26 and later, iPhone only, Swift 6 strict concurrency.
- Codex reviews every PR (`chatgpt-codex-connector[bot]`). Read its
  findings and fix or answer each before calling the work done.

## Building

```sh
swift test --package-path ChangelogKit
xcodebuild -project Changelog.xcodeproj -scheme Changelog \
  -destination 'platform=iOS Simulator,name=iPhone 17' build
```

CI (`.github/workflows/test.yml`) runs both on every PR. Actions are pinned
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
