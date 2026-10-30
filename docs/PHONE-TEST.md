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

Nothing: signing in makes the token. For step 17, have a token made on
the web, Settings, API tokens, with all four ticked: Add notes, Add files,
Upcoming and the activity log.

## The list

1. **Sign in.** "Sign in with Release Notes". iOS asks to use
   notes.yourversionnumber.com; Continue. Sign in on the page if Safari
   isn't already, then "Changelog wants to sign in" with all four ticked:
   Allow. Log opens on today's version, and Settings shows the token's
   name and what it can do. On the web, Settings, API tokens lists it, and
   Activity says "Signed in Changelog as the API token …".
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
8. **Siri and Shortcuts.** "Add a note in Changelog", then say a line:
   Siri answers "Filed in" today's version, never the words, and the note
   is on the web once, with the sticky tag if one is set. In the
   Shortcuts app, "Add a Note" with some text does the same, and "New
   Note" opens Log with the keyboard up, from any tab. With the phone
   locked, "Add a note in Changelog" works too, without unlocking.
9. **The Action Button**, on a phone that has one: Settings, Action
   Button, Controls, "New Note". A press opens Log ready to write. Then
   Shortcut, "Add a Note": a press asks what changed.
10. **Widgets.** On the Home Screen, Today small and medium; on the Lock
    Screen, the round, the rectangular and the one above the time. Each
    shows today's version and "Nothing yet" or "Written today", and a
    note from Siri turns it to "Written today". The medium one lists
    what's coming up; the Lock Screen ones never do. A tap opens Log
    ready to write. The next morning the version has turned without
    opening the app. In Control Center, add "New Note".
11. **Offline.** Airplane mode, a note with a photo, Commit: it waits
    under "Waiting to send". Airplane mode off: it sends, once. A share,
    or "Add a Note" in Shortcuts, made offline says "Saved. Changelog
    sends it when it can." and sends the next time the app opens, once.
12. **Upcoming.** "Add a date" (a birthday), Save, then edit it and delete
    it. The web's Upcoming agrees at each step, and so does the medium
    widget.
13. **Notifications**, in Settings: "Remind me on this phone" (Upcoming
    reminders), "Ask me each morning" (Daily prompt) and the Activity
    notifications switches. A note added on the web or by an agent brings
    a notice minutes or hours later: iOS decides when the app looks.
14. **Activity.** Rows from every channel; "Older" loads more.
15. **The build.** The foot of Settings names the version and the commit
    (`Changelog 0.0.0, build 571b43d`).
16. **Sign out.** Settings, "Sign out", then "Sign out and revoke
    this token". The token shows as revoked on the web, anything still
    waiting stays on the phone, and the widgets say to sign in.
17. **Last, a pasted token.** "Sign in with Release Notes", then Cancel on
    the page: back on the sign-in screen, with nothing to read. Then, under
    "Or use a token", "Paste token" with the token from the web: Log opens.
    Sign out again.

Anything wrong, slow or oddly worded becomes an issue here, with a
screenshot of the dev server's fictional account if it needs one, never of
a real account.
