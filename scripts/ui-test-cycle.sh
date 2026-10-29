#!/bin/bash
# One test cycle of Changelog on a simulator: a note, a photo, Here, a voice
# memo, Upcoming, Activity and Settings, and a share from Photos, against
# the Release Notes dev server's fictional account. Never production: it
# runs only against localhost.
#
#   CHANGELOG_DEV_TOKEN=rn_... scripts/ui-test-cycle.sh ["iPhone 17" [test ...]]
#
# Name tests (testHere, testShareFromPhotos) to run only those.
# Start the dev server first, with places faked (in Release Notes, Node 24):
#   node --import tsx tools/dev-server.ts --fake-places
# It prints the token. CHANGELOG_DEV_URL picks another port.
set -euo pipefail

: "${CHANGELOG_DEV_TOKEN:?a dev server token, which tools/dev-server.ts prints}"
url=${CHANGELOG_DEV_URL:-http://localhost:8790}
case $url in
  http://localhost:* | http://127.0.0.1:*) ;;
  *) echo "CHANGELOG_DEV_URL must be this Mac's dev server, not $url" >&2; exit 64 ;;
esac
if ! curl -fsS -o /dev/null "$url/v1/me" -H "Authorization: Bearer $CHANGELOG_DEV_TOKEN"; then
  echo "No dev server at $url that takes that token." >&2
  exit 1
fi

name=${1:-iPhone 17}
only=(-only-testing:ChangelogUITests)
if (( $# > 1 )); then
  only=()
  for test in "${@:2}"; do only+=("-only-testing:ChangelogUITests/ChangelogUITests/$test"); done
fi
device=$(xcrun simctl list devices available | grep -E "^ +$name \(" | head -1 | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')
[[ -n $device ]] || { echo "No simulator named $name." >&2; exit 1; }
xcrun simctl boot "$device" 2>/dev/null || true
xcrun simctl bootstatus "$device" -b >/dev/null

root=$(cd "$(dirname "$0")/.." && pwd)
dd=$root/build/ui
# Ad-hoc signed, so the app keeps its token in the Keychain.
xcodebuild -project "$root/Changelog.xcodeproj" -scheme Changelog -destination "id=$device" \
  -derivedDataPath "$dd" CODE_SIGN_IDENTITY=- -quiet build-for-testing

bundle=com.yourversionnumber.changelog
xcrun simctl install "$device" "$dd/Build/Products/Debug-iphonesimulator/Changelog.app"
for service in photos location microphone; do xcrun simctl privacy "$device" grant "$service" "$bundle"; done
# Minneapolis, which the dev server names (with --fake-places).
xcrun simctl location "$device" set 44.9778,-93.2650

# A failure keeps its screenshot and UI tree in the result bundle; the
# simulator's sysdiagnose on top took minutes and held up the run.
TEST_RUNNER_CHANGELOG_DEV_TOKEN=$CHANGELOG_DEV_TOKEN TEST_RUNNER_CHANGELOG_DEV_URL=$url \
  xcodebuild -project "$root/Changelog.xcodeproj" -scheme Changelog -destination "id=$device" \
  -derivedDataPath "$dd" "${only[@]}" -resultBundlePath "$dd/cycle-$(date +%Y%m%d-%H%M%S).xcresult" \
  -collect-test-diagnostics never test-without-building
