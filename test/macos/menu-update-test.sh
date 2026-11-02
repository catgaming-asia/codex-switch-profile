#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT_DIR/test/lib/assertions.sh"

if [[ "$(uname -s)" != Darwin ]]; then
  printf 'Skipping update packaging tests outside macOS.\n'
  exit 0
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT HUP INT TERM
FIXTURE_ROOT="$TMP_DIR/repository with spaces"
mkdir -p "$FIXTURE_ROOT/scripts/macos"
cp "$ROOT_DIR/scripts/macos/build-menu-update.sh" "$FIXTURE_ROOT/scripts/macos/"
cp "$ROOT_DIR/macos/CodexProfilesMenu/Info.plist" "$FIXTURE_ROOT/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleShortVersionString 9.8.7' "$FIXTURE_ROOT/Info.plist"

# Exercise the real packaging script; only the Swift build is faked.
cat > "$FIXTURE_ROOT/scripts/macos/build-menu-app.sh" <<'APP_BUILDER'
#!/usr/bin/env bash
set -euo pipefail
fixture_root="$(cd "$(dirname "$0")/../.." && pwd)"
mkdir -p "$MENU_APP_BUILD_DIR/AI Profile.app/Contents/MacOS"
cp "$fixture_root/Info.plist" "$MENU_APP_BUILD_DIR/AI Profile.app/Contents/Info.plist"
printf 'binary' > "$MENU_APP_BUILD_DIR/AI Profile.app/Contents/MacOS/CodexProfilesMenu"
APP_BUILDER
chmod 755 "$FIXTURE_ROOT/scripts/macos/build-menu-app.sh"

OUT="$TMP_DIR/out"
printf 'stale' > "$TMP_DIR/stale.zip"
mkdir -p "$OUT"
cp "$TMP_DIR/stale.zip" "$OUT/AIProfile-1.0.0.zip"
output="$(MENU_UPDATE_OUTPUT_DIR="$OUT" MENU_APP_BUILD_DIR="$TMP_DIR/app" \
  bash "$FIXTURE_ROOT/scripts/macos/build-menu-update.sh" --notes $'Fixes "quotes"\nand lines')"

assert_contains "$output" 'https://data.catgaming.asia/AiProfile/release/' 'upload destination'
[[ ! -e "$OUT/AIProfile-1.0.0.zip" ]] || fail 'older zips are removed'
ZIP="$OUT/AIProfile-9.8.7.zip"
[[ -f "$ZIP" ]] || fail 'the zip is named after the app version'
manifest="$(< "$OUT/latest.json")"
field() { plutil -extract "$1" raw -o - "$OUT/latest.json"; }
assert_equals 'manifest version' '9.8.7' "$(field version)"
assert_equals 'manifest file' 'AIProfile-9.8.7.zip' "$(field file)"
assert_equals 'manifest size' "$(stat -f %z "$ZIP")" "$(field size)"
assert_equals 'manifest sha256' "$(shasum -a 256 "$ZIP" | awk '{print $1}')" "$(field sha256)"
assert_equals 'manifest notes keep quotes and lines' $'Fixes "quotes"\nand lines' "$(field notes)"
assert_contains "$manifest" '"date"' 'manifest date'

unpacked="$TMP_DIR/unpacked"
ditto -x -k "$ZIP" "$unpacked"
assert_equals 'zip holds exactly the app' 'AI Profile.app' "$(ls "$unpacked")"
assert_equals 'packaged bundle identifier' 'asia.catgaming.aiprofile' \
  "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$unpacked/AI Profile.app/Contents/Info.plist")"

# A build with the wrong identifier must not be packaged.
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier example.other' "$FIXTURE_ROOT/Info.plist"
if MENU_UPDATE_OUTPUT_DIR="$TMP_DIR/bad" MENU_APP_BUILD_DIR="$TMP_DIR/app-bad" \
  bash "$FIXTURE_ROOT/scripts/macos/build-menu-update.sh" > "$TMP_DIR/bad.log" 2>&1; then
  fail 'a foreign bundle identifier must be refused'
fi
assert_contains "$(< "$TMP_DIR/bad.log")" 'bundle identifier is not asia.catgaming.aiprofile' 'identifier refusal message'

printf 'Menu app update packaging tests passed.\n'
