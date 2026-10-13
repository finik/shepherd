#!/usr/bin/env bash
# Build the public APK and publish it as a GitHub release.
#
# The public build has no Firebase (push needs your own project; see
# plugin/herdr-push) and reports crashes, nothing else, to Bugsee when
# secrets.json carries a token. It is signed with the release key named in
# android/key.properties, which lives outside the repository.
set -euo pipefail

cd "$(dirname "$0")/.."

if [ ! -f android/key.properties ]; then
  echo "No android/key.properties: the release would be signed with the debug key." >&2
  exit 1
fi

name=$(grep '^version:' pubspec.yaml | sed 's/version: *//; s/+.*//')
tag="v$name"
if gh release view "$tag" >/dev/null 2>&1; then
  echo "Release $tag exists; bump the version in pubspec.yaml first." >&2
  exit 1
fi

defines=()
[ -f secrets.json ] && defines=(--dart-define-from-file=secrets.json)
export SHEPHERD_NO_FIREBASE=1

out=build/release
rm -rf "$out" && mkdir -p "$out"

# One APK for every phone, and a smaller one for 64-bit ARM, which is nearly
# every phone in use. Not --split-per-abi: that adds 1000 per ABI to the
# version code, and a phone holding such a build refuses every later one.
flutter build apk --release "${defines[@]}"
cp build/app/outputs/flutter-apk/app-release.apk "$out/shepherd-$name.apk"
flutter build apk --release --target-platform android-arm64 "${defines[@]}"
cp build/app/outputs/flutter-apk/app-release.apk "$out/shepherd-$name-arm64.apk"

cat > "$out/notes.md" <<EOF
**Install:** open this page on your Android phone, download
\`shepherd-$name-arm64.apk\` (or \`shepherd-$name.apk\` if your phone is not
64-bit ARM), and open it. Android asks once to allow installs from your
browser or file manager. Then add your machine: host, user, and a key the app
can generate for you.

**Your host needs** \`sshd\`, Herdr 0.9 or later, and Python 3. Nothing is
installed on it.

**Notifications:** this build has no push of its own; choose In-app in
Settings, or have the Herdr push plugin send to the ntfy app
([plugin/herdr-push](https://github.com/finik/shepherd/tree/main/plugin/herdr-push)).

**Crash reports:** when the app crashes, a report goes to Bugsee — the error,
the device model and Android version, and the app's recent log lines. It
records no screen, video or screenshots, and you are never asked to report a
bug.

**Platforms:** Android. Shepherd is a Flutter app, but it has never been built
or run on iOS.

Signed with the release key, SHA-256 fingerprint
\`$(keytool -list -keystore "$(sed -n 's/^storeFile=//p' android/key.properties)" \
  -storepass "$(sed -n 's/^storePassword=//p' android/key.properties)" 2>/dev/null \
  | sed -n 's/.*SHA-256): //p')\`.
EOF

gh release create "$tag" "$out/shepherd-$name-arm64.apk" "$out/shepherd-$name.apk" \
  --title "Shepherd $name" --notes-file "$out/notes.md"
echo "released $tag"
