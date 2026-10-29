# A pass on a real phone

`scripts/ui-test-cycle.sh` drives the app on a simulator against the dev
server. A simulator has no camera, records with the Mac's microphone,
fakes its location and never goes offline, and a share from Photos there
is one small picture. So each new TestFlight build also gets a pass by hand
on a real phone.

A TestFlight build is a release build: it talks only to Release Notes, so
this pass is the owner of an account using the app on it, by hand, the way
anyone with the build will. It is never an agent's or a script's: they
stay on the dev server (the rule in `AGENTS.md`). Its notes are real and
go in the next morning's email; swipe one left on Log and Delete it if it
shouldn't. An issue about one never quotes it.

An Android version takes the same list as what it must do, with the dev
server first (the onramp is in the Release Notes repo,
[`site/guide/api/clients.md`](https://github.com/jthingelstad/yvn-release-notes/blob/main/site/guide/api/clients.md)).
The words in quotes are the iPhone app's.

## Before you start

On the web, Settings, API tokens, make a token with all four ticked: Add
notes, Add files, Upcoming and the activity log.

## The list

1. **Sign in.** "Paste token", then "Sign in". Log opens on today's
   version.
2. **A note.** A line with a #tag, then Commit. It shows under Today and
   on the web. Swipe it left: Edit (change a word, Save), then Delete.
3. **Tags.** Tap a pinned tag to add it. Touch and hold one: it goes on
   every note until Settings, "Stop adding #… to every note". Settings,
   Pinned tags: add one; it shows on the web too.
4. **Photos.** "Add photos" (two or three) and "Take a photo" on one
   note, then Commit. The web note has every photo.
5. **A voice memo.** The microphone, ten seconds, stop, Commit. It plays
   on the web.
6. **Here.** The location button; allow While Using. The place shows by
   Commit: tap it to pick a business nearby or "Leave the place off". Then
   Settings, Place, "Add where I am" on: the next note finds it by itself.
   Each Here is a lookup Release Notes pays for, so a few is plenty.
7. **The share sheet.** From Photos, three or four big photos at once;
   from Safari, a link; from Files, a PDF; from Voice Memos, a recording.
   Each makes exactly one note. A video too, to see what it says: Release
   Notes doesn't keep video.
8. **Offline.** Airplane mode, a note with a photo, Commit: it waits
   under "Waiting to send". Airplane mode off: it sends, once. A share made
   offline sends the next time the app opens.
9. **Upcoming.** "Add a date" (a birthday), Save, then edit it and delete
   it. The web's Upcoming agrees at each step.
10. **Notifications**, in Settings: "Remind me on this phone" (Upcoming
    reminders), "Ask me each morning" (Daily prompt) and the Activity
    notifications switches. A note added on the web or by an agent brings
    a notice minutes or hours later: iOS decides when the app looks.
11. **Activity.** Rows from every channel; "Older" loads more.
12. **The build.** The foot of Settings names the version and the commit
    (`Changelog 0.0.0, build 571b43d`).
13. **Last, sign out.** Settings, "Sign out", then "Sign out and revoke
    this token". The token shows as revoked on the web, and anything still
    waiting stays on the phone.

Anything wrong, slow or oddly worded becomes an issue here, with a
screenshot of the dev server's fictional account if it needs one, never of
a real account.
