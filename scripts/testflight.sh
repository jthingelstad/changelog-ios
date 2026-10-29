#!/bin/bash
# Archives Changelog for the App Store and uploads it to TestFlight, for
# internal testers only (Config/ExportOptions-TestFlight.plist). Builds come
# from a clean commit on main: Apple's build number is the commit count, so
# it only goes up, and Settings names the commit.
#
# Needs the developer account signed in to Xcode (Settings > Accounts), its
# team in Config/Signing.local.xcconfig, and the app made in App Store
# Connect for com.yourversionnumber.changelog. The first run registers the
# app's ids and its App Group with Apple and makes the signing certificates.
#
# Xcode's sign-in is there only for a login session (Terminal). An App Store
# Connect API key works from any shell instead: a team key with the Admin
# role (signing with Apple's cloud-managed certificate takes Admin), its
# AuthKey_<key id>.p8 in ~/.appstoreconnect/private_keys, and its ids in
# Config/AppStoreConnect.local, which git ignores:
#   ASC_KEY_ID=<key id>
#   ASC_ISSUER_ID=<issuer id>
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

if ! grep -qE '^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*[A-Z0-9]{10}' Config/Signing.local.xcconfig 2>/dev/null; then
  echo "Put DEVELOPMENT_TEAM = <your team ID> in Config/Signing.local.xcconfig first." >&2
  exit 1
fi
if [[ -n $(git status --porcelain) ]]; then
  echo "The checkout has changes. TestFlight builds come from a clean commit." >&2
  exit 1
fi
git fetch -q origin main
if ! git merge-base --is-ancestor HEAD origin/main; then
  echo "This commit isn't on main. TestFlight builds come from main." >&2
  exit 1
fi

auth=()
if [[ -f Config/AppStoreConnect.local ]]; then
  key_id=$(sed -nE 's/^ASC_KEY_ID=([A-Z0-9]+)$/\1/p' Config/AppStoreConnect.local)
  issuer=$(sed -nE 's/^ASC_ISSUER_ID=([0-9a-f-]+)$/\1/p' Config/AppStoreConnect.local)
  key=$HOME/.appstoreconnect/private_keys/AuthKey_$key_id.p8
  if [[ -z $key_id || -z $issuer || ! -f $key ]]; then
    echo "Config/AppStoreConnect.local needs ASC_KEY_ID and ASC_ISSUER_ID, and the key in $HOME/.appstoreconnect/private_keys." >&2
    exit 1
  fi
  auth=(-authenticationKeyPath "$key" -authenticationKeyID "$key_id" -authenticationKeyIssuerID "$issuer")
fi

out=$root/build/testflight
rm -rf "$out"
echo "Changelog $(scripts/version.sh), build $(git rev-list --count HEAD) ($(git rev-parse --short HEAD))"
xcodebuild -project Changelog.xcodeproj -scheme Changelog -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$out/Changelog.xcarchive" \
  -allowProvisioningUpdates ${auth[@]+"${auth[@]}"} -quiet archive
xcodebuild -exportArchive -archivePath "$out/Changelog.xcarchive" \
  -exportOptionsPlist Config/ExportOptions-TestFlight.plist -exportPath "$out/export" \
  -allowProvisioningUpdates ${auth[@]+"${auth[@]}"}
echo "Uploaded. App Store Connect takes a few minutes to process it; then it is in TestFlight."
