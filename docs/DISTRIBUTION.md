# From TestFlight to the App Store

Changelog goes out in three steps: TestFlight for Jamie's developer team,
TestFlight for a few people who use Release Notes, then the App Store.
Each step is Jamie's call, and so is each upload: it goes to Apple and to
people's phones.

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
  groups." The upload for outside testers leaves
  `testFlightInternalTestingOnly` out of the export options.
- **Test information**, under TestFlight in App Store Connect: a Beta App
  Description (required), a feedback email (also the reply-to of the
  invitations), a contact, and Release Notes' privacy page
  (`https://notes.yourversionnumber.com/privacy/`) as the privacy policy.
- **A sign-in for Apple's reviewers.** Apple asks for a demo account that
  "must not expire". Changelog signs in with a token, not a username and
  password, so the review notes carry a token instead: on an account kept
  for review, with all four boxes ticked, expiring never, named "App
  Review", and the steps to paste it. Revoking it breaks the next review,
  so it stays. It is never committed here.
- **An external group**, invited by email (the address of each tester's
  Apple Account) or by a public link capped at a few people. Each tester
  installs TestFlight, and needs a Release Notes account to make a token
  from; the sign-in screen says how.
- **Review.** The first build gets a full review, about a day. Apple says
  later builds "for the same version might not", but Changelog's version
  moves every day, so expect most builds an outside tester gets to wait
  for a review. Apple takes six builds a day for review, one of each
  version at a time. A build stays installable for 90 days.

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
  opens the web's page for it.

Every App Store version gets a full review, and each must be higher than
the last, which Changelog's daily version is.

## Open

- Whether the App Store takes 0.0.0 as well as TestFlight did. The first
  submission says.
- Jamie's calls: when outside testers start and who they are, the review
  account, the listing's words and the privacy answers, and when the App
  Store comes.
