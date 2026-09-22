#!/usr/bin/env bash
# Build a release APK and publish it where the phone can pull it over SSH.
#
# The app checks ~/.shepherd/version.txt against its own build number and
# offers the update in Settings and on the Machines screen. No adb, no store.
set -euo pipefail

cd "$(dirname "$0")/.."

build=$(grep '^version:' pubspec.yaml | sed 's/.*+//')
flutter build apk --release

mkdir -p ~/.shepherd
cp build/app/outputs/flutter-apk/app-release.apk ~/.shepherd/shepherd.apk
printf '%s' "$build" > ~/.shepherd/version.txt

echo "published build $build ($(du -h ~/.shepherd/shepherd.apk | cut -f1)) to ~/.shepherd/"
