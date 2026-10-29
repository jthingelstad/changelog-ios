#!/bin/bash
# Changelog's version number, by Your Version Number's arithmetic, the way
# Release Notes numbers its own builds: counted from Changelog's start on
# 29 October 2026 (Jamie, 2026-10-29: "use today as the start date") to the
# day a build is made, in Chicago, so it reads the same to everyone. MAJOR
# is decades, MINOR the year within the decade, PATCH the days since the
# last anniversary: 0.0.0 on the first day, 0.0.1 the next, 0.1.0 a year on.
#
#   scripts/version.sh                  the version a build made now carries
#   scripts/version.sh 2027-03-01       the version on a day
#   scripts/version.sh test             checks the arithmetic
#   scripts/version.sh stamp <plist>    stamps a built Info.plist
#
# A build's number for Apple (CFBundleVersion) has to be whole numbers, so
# it is the count of commits; the commit itself goes in ChangelogCommit,
# and Settings shows it as the build.
set -euo pipefail

START=2026-10-29
ZONE=America/Chicago

leap() { (( $1 % 4 == 0 && ($1 % 100 != 0 || $1 % 400 == 0) )); }

# The anniversary of a MM-DD in a year; 29 February is 1 March in the rest.
anniversary() {
  if [[ $2 == 02-29 ]] && ! leap "$1"; then echo "$1-03-01"; else echo "$1-$2"; fi
}

# Days from one YYYY-MM-DD to another, counted at noon UTC so no clock
# change moves them.
days() {
  local from to
  from=$(date -j -u -f '%Y-%m-%d %H' "$1 12" +%s)
  to=$(date -j -u -f '%Y-%m-%d %H' "$2 12" +%s)
  echo $(( (to - from) / 86400 ))
}

# The version on day $2 of something that started on $1.
version() {
  local since=$1 day=$2 year last age
  year=$((10#${day%%-*}))
  last=$(anniversary "$year" "${since#*-}")
  if [[ $day < $last ]]; then
    year=$((year - 1))
    last=$(anniversary "$year" "${since#*-}")
  fi
  age=$((year - 10#${since%%-*}))
  echo "$((age / 10)).$((age % 10)).$(days "$last" "$day")"
}

check() {
  local got
  got=$(version "$1" "$2")
  if [[ $got != "$3" ]]; then
    echo "version $1 on $2: got $got, want $3" >&2
    return 1
  fi
}

case "${1:-}" in
  test)
    # Your Version Number's own edge cases (yourversionnumber.com's
    # arithmetic tests), then Changelog's first days.
    check 1990-09-15 2026-09-15 3.6.0
    check 2026-09-15 2026-09-15 0.0.0
    check 1966-09-15 2026-09-15 6.0.0
    check 2004-02-29 2026-03-01 2.2.0
    check 2004-02-29 2028-02-29 2.4.0
    check 2004-02-29 2026-02-28 2.1.364
    check 1974-01-15 2027-01-01 5.2.351
    check "$START" 2026-10-29 0.0.0
    check "$START" 2026-10-30 0.0.1
    check "$START" 2026-11-01 0.0.3
    check "$START" 2027-03-14 0.0.136
    check "$START" 2027-10-28 0.0.364
    check "$START" 2027-10-29 0.1.0
    check "$START" 2028-10-28 0.1.365
    check "$START" 2036-10-29 1.0.0
    echo "version arithmetic: ok"
    ;;
  stamp)
    plist=${2:?the built Info.plist}
    root=$(cd "$(dirname "$0")/.." && pwd)
    number=$(version "$START" "$(TZ=$ZONE date +%Y-%m-%d)")
    commit=$(git -C "$root" rev-parse HEAD 2>/dev/null || true)
    count=$(git -C "$root" rev-list --count HEAD 2>/dev/null || echo 1)
    plutil -replace CFBundleShortVersionString -string "$number" "$plist"
    plutil -replace CFBundleVersion -string "$count" "$plist"
    plutil -replace ChangelogCommit -string "$commit" "$plist"
    plutil -replace ChangelogBuiltAt -string "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$plist"
    echo "Changelog $number, build ${commit:0:7}"
    ;;
  ????-??-??)
    version "$START" "$1"
    ;;
  "")
    version "$START" "$(TZ=$ZONE date +%Y-%m-%d)"
    ;;
  *)
    echo "usage: scripts/version.sh [test | stamp <Info.plist> | YYYY-MM-DD]" >&2
    exit 64
    ;;
esac
