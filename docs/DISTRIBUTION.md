# From TestFlight to the App Store

Changelog goes out in three steps: TestFlight for Jamie's developer team,
TestFlight for a few people who use Release Notes, then the App Store.
Each step is Jamie's call, and so is each upload, since it goes to Apple
and to people's phones, with one standing exception: a build of main for
internal testers after work merges (Jamie, 29 October 2026).

## 1. Internal testers (now)

The app is made in App Store Connect for `com.yourversionnumber.changelog`,
with an internal group of testers. `scripts/testflight.sh` uploads a clean
commit on main, marked internal only (`testFlightInternalTestingOnly` in
`Config/ExportOptions-TestFlight.plist`). Internal builds need no review
from Apple. Each one gets [a pass on a real phone](PHONE-TEST.md).

The team needs one iPhone registered to it before the first archive:
automatic signing archives with a development profile, and Apple makes
one only for a team with a device. Building to a phone once from Xcode,
with Developer Mode on, registers it. App Store Connect took 0.0.0 as the
first version.

## 2. A few outside testers

Apple calls them external testers. What it takes:

- **A build that isn't internal only.** Apple: "Builds uploaded as
  TestFlight Internal Only … can only be added to internal tester
  groups." `scripts/testflight.sh --external` leaves
  `testFlightInternalTestingOnly` out of the export options. It still
  uploads only a clean commit on main.
- **Test information**, under TestFlight in App Store Connect: a Beta App
  Description (required), a feedback email (also the reply-to of the
  invitations), a contact, and Release Notes' privacy page
  (`https://notes.yourversionnumber.com/privacy/`) as the privacy policy.
- **A sign-in for Apple's reviewers.** Apple asks for a demo account that
  "must not expire". "Sign in with Release Notes" asks for a code by
  email, which a reviewer can't get, so the review details carry a token
  instead, in the demo password: on an account kept for review, with all
  four boxes ticked, expiring never, named "App Review". The notes say to
  paste it under "Or use a token" and tap "Sign in with this token".
  Revoking it breaks the next review, so it stays. It is never committed
  here, and never printed: `scripts/asc.swift` puts it in from a file.
- **An external group**, invited by email (the address of each tester's
  Apple Account) or by a public link capped at a few people. Each tester
  installs TestFlight and needs a Release Notes account, which comes with
  a Weekly Thing subscription; "Sign in with Release Notes" does the
  rest.
- **Review.** The first build gets a full review, about a day. Apple says
  later builds "for the same version might not", but Changelog's version
  moves every day, so expect most builds an outside tester gets to wait
  for a review. Apple takes six builds a day for review, one of each
  version at a time. A build stays installable for 90 days.

### The steps, once Jamie says go

`scripts/asc.swift METHOD PATH [body.json] [--token-file <file>]` makes one
App Store Connect API call with the team key (the ids in
`Config/AppStoreConnect.local`, as `testflight.sh` reads them). What comes
back has the demo password and anything shaped like a token blanked. The
bodies hold Jamie's contact details and the token, so they live in
`build/`, which git ignores, never here.

1. On the web, make the review account and its token as above. The token
   goes straight from the page into a file in `build/` that only this
   user can read.
2. `POST /v1/betaAppLocalizations` (en-US): the Beta App Description,
   the feedback email and the privacy page.
3. `PATCH /v1/betaAppReviewDetails/<app id>`: the contact's name, email
   and phone, `demoAccountRequired`, the review account's email as the
   name, `{{REVIEW_TOKEN}}` as the password (with `--token-file`), and
   the notes.
4. `scripts/testflight.sh --external` from main, then wait for the build
   to finish processing (`GET /v1/builds?filter[app]=<app id>`).
5. `POST /v1/betaGroups` for the outside testers' group, add the build to
   it (`POST /v1/betaGroups/<id>/relationships/builds`), and send it for
   review (`POST /v1/betaAppReviewSubmissions`).
6. Once it passes, invite the testers (`POST /v1/betaTesters`, by email),
   or turn on the group's public link with a limit.

## 3. The App Store

On top of the above:

- **The listing:** name, subtitle, description, keywords, category
  (Productivity), the guide as the support page, the privacy page, the age
  rating questionnaire, and free.
- **Screenshots** from a simulator on the dev server's fictional account,
  never a real one: this repo's rule, and the store's.
- **App Privacy**, the answers on the store page: what the app sends to
  Release Notes, linked to the person (notes, photos, voice memos and
  files, and the spot where a note was written when Here is on). No
  tracking.
- **The same review sign-in.** Settings has "Delete your account", which
  opens the web's page for it, and "Privacy", the privacy page (so does
  the sign-in screen).

Every App Store version gets a full review, and each must be higher than
the last, which Changelog's daily version is.

## Open

- Whether the App Store takes 0.0.0 as well as TestFlight did. The first
  submission says.
- Jamie's calls: who the outside testers are, the review contact's phone,
  the listing's words and the privacy answers, and when the App Store
  comes. Outside testers and the review account are approved (Jamie,
  29 October 2026).
