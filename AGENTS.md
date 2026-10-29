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
  `Hashtags` (a port of Release Notes' `packages/domain/tags.ts`; keep them
  in step), `TokenStore` (the Keychain). It has its own tests:
  `swift test --package-path ChangelogKit`.
- `Changelog/` is the SwiftUI app: `AppModel` holds the state, `Views/` the
  screens (Log, Activity, Settings, sign-in).
- `Changelog.xcodeproj` uses synchronized folders, so new files in
  `Changelog/` need no project edit.

## Rules

- This repo is public. Never commit real notes, real versions, real
  account details, tokens, screenshots of a real account, or Apple account
  or signing details. Examples use the dev server's fictional account.
- Never test against production. Run the Release Notes dev server
  (`tools/dev-server.ts`, port 8790) and point a debug build at it.
- No third-party packages. Apple's frameworks only.
- Never log, print or put in an error message a token or a note's text.
- Every write goes through the Outbox with its idempotency key, so a resend
  never makes a second note.
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
