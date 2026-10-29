# Changelog

A fast iPhone app for sending notes into
[Release Notes](https://notes.yourversionnumber.com), the daily email from
Your Version Number. It is not a second Release Notes: you read, search and
look back on the web. Changelog is for getting things in, in two taps.

- **Log** a line, with one-tap tags. The button says Commit.
- **Never lose a note.** Everything goes through an offline queue, and a
  resend never makes a duplicate.
- **Check** what happened: the activity log, from every channel, without
  the words.
- **Reminders** from your Upcoming dates, as notifications when each
  morning's email is due, in its words. Off until you turn them on.
- Later: photos, voice memos and places (0.2), adding Upcoming dates,
  Shortcuts, the Action Button and widgets (0.4).

It talks only to Release Notes' public `/v1` API, with a token you make in
Release Notes' Settings. The API is designed in
[`docs/API.md`](https://github.com/jthingelstad/yvn-release-notes/blob/main/docs/API.md)
in the Release Notes repo, which is also the guide for anyone writing their
own client, on any platform.

## Building

Xcode 26 or later, iOS 26 or later. No third-party packages.

```sh
swift test --package-path ChangelogKit
xcodebuild -project Changelog.xcodeproj -scheme Changelog \
  -destination 'platform=iOS Simulator,name=iPhone 17' build
```

`ChangelogKit/` holds everything that isn't a screen (the API client, the
offline queue, hashtags, the token's storage) and is tested on its own. The
app in `Changelog/` is SwiftUI on top of it.

The `/v1` API is being built in Release Notes now, in phases; until its
first phase is live, this app has nothing to talk to.

To try it without touching real notes, run the Release Notes dev server
(`npm run build`, then `node --import tsx tools/dev-server.ts` in that repo;
it serves the API against a fictional account and prints a token), choose "Dev server" on the
sign-in screen of a debug build, and paste the token.

To run it on your own iPhone, set your team under Signing & Capabilities.

## License

MIT. See [LICENSE](LICENSE).
