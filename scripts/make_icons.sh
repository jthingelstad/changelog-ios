#!/bin/sh
# Makes the app icon sets from the 2026-11-01 icon study
# (docs/design/icon-study-2026-11-01): the primary "Versions" icon and the
# four Supporting Member editions. Each is the study's 1254 pixel master,
# resized to 1024 by sips, opaque sRGB. sips writes a fresh file, so the
# masters' content credentials chunk does not travel into the app.
# Rerun after the study's artwork changes: sh scripts/make_icons.sh
set -eu
cd "$(dirname "$0")/.."
study=docs/design/icon-study-2026-11-01/icons
assets=Changelog/Assets.xcassets

make() { # make <study name> <icon set>
  set_dir="$assets/$2.appiconset"
  mkdir -p "$set_dir"
  sips -s format png -m '/System/Library/ColorSync/Profiles/sRGB Profile.icc' \
    -z 1024 1024 "$study/changelog-$1.png" --out "$set_dir/icon-1024.png" >/dev/null
  cat > "$set_dir/Contents.json" <<JSON
{
  "images" : [ { "filename" : "icon-1024.png", "idiom" : "universal", "platform" : "ios", "size" : "1024x1024" } ],
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON
}

make primary AppIcon
make paper AppIcon-Paper
make copper AppIcon-Copper
make terminal AppIcon-Terminal
make afterglow AppIcon-Afterglow
