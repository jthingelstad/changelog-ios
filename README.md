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
- **Upcoming**: the birthdays, anniversaries, trips and events ahead, to
  add, change and remove, each in the line the email gives it.
- **Notifications**, each off until you turn it on: Upcoming reminders
  when each morning's email is due, in its words; a daily prompt with
  the day's version ("What changed?"); and activity from elsewhere (notes
  an agent or an import added, problems, badges), never with a note's
  words.
- **Photos, voice memos and where you are** on a note: from the library
  or the camera, recorded in the app, and the neighbourhood or city with a
  business nearby to pick. They wait on the phone with the note until it
  is sent. Files need a token with "Add files" ticked.
- **Share** a photo, a PDF, a voice memo, a link or some text from any app:
  Changelog is in the share sheet, with a line to go with it and Commit.
  It sends straight away when it can; what it can't, the app sends next
  time it opens, still as one note.
- Later: Shortcuts, the Action Button and widgets.

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

Changelog numbers its builds the way Release Notes does, by Your Version
Number's arithmetic from its own start on 29 October 2026 to the day a
build is made, in Chicago: 0.0.0 on the first day, 0.1.0 a year on.
`scripts/version.sh` stamps every build with it and the commit, which the
foot of Settings shows (`Changelog 0.0.0, build 571b43d`).

`ChangelogKit/` holds everything that isn't a screen (the API client, the
offline queue, hashtags, the token's storage) and is tested on its own. The
app in `Changelog/` is SwiftUI on top of it, and the share sheet's
Changelog is `ShareExtension/`.

The `/v1` API is being built in Release Notes now, in phases; until its
first phase is live, this app has nothing to talk to.

To try it without touching real notes, run the Release Notes dev server
(`npm run build`, then `node --import tsx tools/dev-server.ts` in that repo;
it serves the API against a fictional account and prints a token), choose "Dev server" on the
sign-in screen of a debug build, and paste the token.

To run it on your own iPhone, sign in to your Apple developer account in
Xcode (Settings, Accounts), then put your team in a file git ignores, so
it never lands in this repo:

```sh
echo 'DEVELOPMENT_TEAM = <your team ID>' > Config/Signing.local.xcconfig
```

Every target signs with it (`Config/Signing.xcconfig`); leave the Team
menus in Xcode alone, since a team picked there is written into the
project. The app and the share extension share an App Group
(`group.com.thingelstad.changelog`) for the token and for shares, which
automatic signing registers on the first build for a phone. With your own
team, change the `com.thingelstad` bundle ids and the group too.

## License

MIT. See [LICENSE](LICENSE).
