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

Nothing: signing in makes the token. For step 18, a second account to
sign in to (another address of yours). For step 19, have a token made on
the web, Settings, API tokens, with all five ticked: Add notes, Add files,
Read all your notes, Upcoming and the activity log. For steps 20 and 21, a
token with the same ticks but without Read all your notes, and a note on the
web, an emailed note, and a note from another channel with a photo, a voice
memo and a transcript.

## The list

1. **Sign in.** "Sign in with Release Notes". iOS asks to use
   notes.yourversionnumber.com; Continue. Sign in on the page if Safari
   isn't already, then "Changelog wants to sign in" with all five ticked:
   Allow. Log opens on today's version, and Settings shows the token's
   name and what it can do. On the web, Settings, API tokens lists it, and
   Activity says "Signed in Changelog as the API token …".
2. **A note.** A line with a #tag, then Commit. It shows under Today with
   its words, and on the web. Swipe it left: Edit (change a word, Save; the
   new words show under Today), then Delete, which asks first. Leave one
   note under Today, swipe Changelog away in the app switcher and open it
   again: it opens, with the note's words back under Today (builds 52 and
   53 closed on opening here, 2026-10-30).
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
7. **Moments.** The Moments button, beside the location button, opens
   Apple's suggestions (no permission to ask for). Pick one from a day or
   two back with a workout, a song or a place in it: the box fills with a
   plain line for each ("Walked 3.2 mi in 48 min", "Listened to … by …")
   and its photos, its place shows by Commit, named once, and under the
   box "Files on" that day (or "Files in" its version, if Today has shown
   it), with "File to today" in its menu. Nothing goes until Commit; then
   the web has the note on that day. One with a video says the video
   isn't on the note. If the button does nothing, the App ID is missing
   the Journaling Suggestions capability.
8. **The share sheet.** From Photos, three or four big photos at once;
   from Safari, a link; from Files, a PDF; from Voice Memos, a recording.
   Each makes exactly one note. A video too, to see what it says: Release
   Notes doesn't keep video.
9. **Siri and Shortcuts.** "Add a note in Changelog", then say a line:
   Siri answers "Filed in" today's version, never the words, and the note
   is on the web once, with the sticky tag if one is set. In the
   Shortcuts app, "Add a Note" with some text does the same, and "New
   Note" opens Log with the keyboard up, from any tab. With the phone
   locked, "Add a note in Changelog" works too, without unlocking.
10. **The Action Button**, on a phone that has one: Settings, Action
    Button, Controls, "New Note". A press opens Log ready to write. Then
    Shortcut, "Add a Note": a press asks what changed.
11. **Widgets.** On the Home Screen, Today small and medium; on the Lock
    Screen, the round, the rectangular and the one above the time. Each
    shows today's version and "Nothing yet" or "Written today", and a
    note from Siri turns it to "Written today". The medium one lists
    what's coming up; the Lock Screen ones never do. A tap opens Log
    ready to write. The next morning the version has turned without
    opening the app. In Control Center, add "New Note".
12. **Offline.** Airplane mode, a note with a photo, Commit: it waits
    under "Waiting to send", "Waiting for a connection". Airplane mode
    off, the app still open: it sends, once, without leaving Log. A note
    committed just before going to the Home Screen still sends. A share,
    or "Add a Note" in Shortcuts, made offline says "Saved. Changelog
    sends it when it can." and sends the next time the app opens, once.
13. **Upcoming.** "Add a date" (a birthday), Save, then edit it and delete
    it. The web's Upcoming agrees at each step, and so does the medium
    widget.
14. **Notifications**, in Settings: "Remind me on this phone" (Upcoming
    reminders), "Ask me each morning" (Daily prompt) and the Activity
    notifications switches. A note added on the web or by an agent brings
    a notice minutes or hours later: iOS decides when the app looks.
15. **Activity.** Rows from every channel; "Older" loads more.
16. **The build and the icon.** The foot of Settings names the version, the
    commit and when it was made (`Changelog 0.0.0, build 571b43d, made Oct
    29 at 1:25 PM CDT.`). "Privacy", under Release Notes, opens the privacy
    page. On the Home Screen, touch and hold, Edit, Customize: in Dark,
    Tinted and Clear the icon stays three stacked v marks, apart from
    Release Notes' single v. The mark beside "Changelog" atop each tab,
    and in the widgets, is the same Versions tile; on a Tinted Home Screen
    the widgets' mark shows as a toned tile, not a flat square. For a
    Supporting Member, Settings, "App icon" offers five: choose one, OK
    iOS's alert, and the Home Screen shows it; Versions puts it back.
    Anyone else sees no "App icon" at all.
17. **Sign out.** Settings, "Sign out", then "Sign out and revoke
    this token". The token shows as revoked on the web, anything still
    waiting stays on the phone, Notification Center holds nothing of
    Changelog's, and the widgets say to sign in. In Airplane Mode the same
    steps sign out too, and the sign-in screen says to end the token on
    the web, since Release Notes couldn't be reached to end it.
18. **Another account's note.** Signed in to your account, Airplane mode,
    a note with a photo, Commit: it waits. Settings, "Sign out", Airplane
    mode off, then sign in to the second account. The note is under
    "Waiting to send", "Written while signed in to another account.", with
    "Send to this account" and "Delete", and goes nowhere by itself: on
    the web, neither account has it. "Delete" asks first; Cancel. "Send to
    this account": it goes, once, to the second account, photo and all.
    Then the same again, but sign back in to your own account instead: the
    note sends by itself, once, as before.
19. **Last, a pasted token.** "Sign in with Release Notes", then Cancel on
    the page: back on the sign-in screen, with nothing to read. Then, under
    "Or use a token", "Paste token" with the token from the web: Log opens.
    Sign out again.
20. **Allow reading.** Sign in with the four-tick token. It still captures.
    Turn a reminder switch on, and in Airplane mode leave a note waiting. Back
    online, tap Notes, then "Allow reading", and on the page Allow with all
    five: Notes opens, the switch is still on, the note went once, and on the
    web the old token shows revoked and the new one "Changelog 2". Do it again
    from a four-tick token while sharing a photo in: it goes once. Do it again
    and untick "Read all your notes": it says so and nothing changes.
21. **Reading.** Notes shows today's notes from every channel. Open the emailed
    note and edit it, then delete a note (the emailed one says its email goes
    too). A note with a photo, a voice memo and a transcript: the photo opens
    whole, the memo plays, the transcript reads. A rich note: bold, italic, a
    list, a quote and a link. Scroll back through Earlier, into a day with
    weather (its credit shows beside it), and down a day long enough to page.
22. **The lock.** Settings, "Lock reading", on (Face ID asks). Leave the app and
    come back: Notes asks, and the app switcher's picture shows no note. Say no:
    Notes says Locked, and Log's Today shows only what this phone wrote. Log,
    the share sheet and "Add a note in Changelog" all still work, locked.

23. **Check-ins.** Settings, "Notice where I stop" is off. Tap "Check in now" on
    Log with it off: While Using is enough, it says "Checked in at …" and Activity
    has the row. Turn the switch on and pick Always at iOS's question; pick less
    and it says what that means and links to the Settings app. Leave for
    somewhere, stop for a while, and come back: without opening the app, the
    stop is on the web's Activity, which only real delivery can prove. Then the
    same with the phone locked, and in Airplane mode (it waits on Log, says so
    without saying where, and sends once back online). Then the one a simulator
    can't show at all: force-quit the app, stop somewhere, and see whether iOS
    still started it and the stop arrived. A row opens its page locked too:
    name it, take the name off, Remember it, Write about this, Delete. Settings,
    Remembered places: rename and forget one. Delete all check-ins, and the
    places stay. Sign out: the switch goes off, check-ins stay on the web, and
    "Visits from the test" has gone.

24. **The Check In control and the map.** Add "Check In" to Control Center, the
    Lock Screen and the Action Button. Each press opens Activity and says
    "Checked in at …", with the app closed, in the background and on another tab.
    With location off for Changelog it says so instead. Signed out, it opens the
    sign-in page and nothing checks in on signing in. Activity, Map: a dot for
    each place, in the right place, and one place's stops under one dot. Tap a
    dot, open a stop, Write about this, and Log opens with the sheet gone.
    Delete a stop from there and its dot goes. Notes (Face ID if locked): a ring
    for each spot with notes, rings gathering into a count as you zoom out, and
    a ring opens its notes. A year, a #tag and some words each narrow it, and
    words or a tag hide the check-ins. Trails joins the check-ins with a solid
    line and the notes with a dotted one, oldest first. Lock reading: the notes
    and the search go.

Anything wrong, slow or oddly worded becomes an issue here, with a
screenshot of the dev server's fictional account if it needs one, never of
a real account.
