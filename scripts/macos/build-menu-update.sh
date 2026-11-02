#!/usr/bin/env bash
# Packages AI Profile for the in-app updater: builds the app, zips it and
# writes latest.json beside the zip. Nothing is uploaded; copy the zip, then
# latest.json, into the public AiProfile/release/ folder (https://data.catgaming.asia/AiProfile/release/)
# and purge the CDN cache for latest.json.
#   scripts/macos/build-menu-update.sh [--notes "<text>"]

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUTPUT_DIR="${MENU_UPDATE_OUTPUT_DIR:-$ROOT_DIR/build/macos/update}"
APP_BUILD_DIR="${MENU_APP_BUILD_DIR:-$ROOT_DIR/build/macos}"
BUNDLE_ID="asia.catgaming.aiprofile"
UPDATE_URL="https://data.catgaming.asia/AiProfile/release/"

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

NOTES=""
while (($# > 0)); do
  case "$1" in
    --notes)
      (($# >= 2)) || die "--notes needs text"
      NOTES="$2"
      shift 2
      ;;
    --notes=*)
      NOTES="${1#--notes=}"
      shift
      ;;
    -h | --help)
      printf 'Usage: scripts/macos/build-menu-update.sh [--notes "<text>"]\n'
      exit 0
      ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ "$(uname -s)" == "Darwin" ]] || die "the AI Profile update can only be packaged on macOS."

MENU_APP_BUILD_DIR="$APP_BUILD_DIR" "$ROOT_DIR/scripts/macos/build-menu-app.sh"
APP="$APP_BUILD_DIR/AI Profile.app"
INFO="$APP/Contents/Info.plist"
[[ -f "$INFO" ]] || die "the build did not produce $APP"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO")" == "$BUNDLE_ID" ]] \
  || die "the built app's bundle identifier is not $BUNDLE_ID"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO")"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "the app version must be x.y.z (found: $VERSION)"

mkdir -p "$OUTPUT_DIR"
# Keep only the release being prepared.
rm -f "$OUTPUT_DIR"/AIProfile-*.zip "$OUTPUT_DIR/latest.json"
FILE="AIProfile-$VERSION.zip"
ZIP="$OUTPUT_DIR/$FILE"
ditto -c -k --keepParent "$APP" "$ZIP"
SHA="$(shasum -a 256 "$ZIP" | awk '{print $1}')"
SIZE="$(stat -f %z "$ZIP")"
DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

VERSION="$VERSION" DATE="$DATE" NOTES="$NOTES" FILE="$FILE" SIZE="$SIZE" SHA="$SHA" \
  perl -MJSON::PP -e '
    print JSON::PP->new->canonical->pretty->encode({
      version => $ENV{VERSION}, date => $ENV{DATE}, notes => $ENV{NOTES},
      file => $ENV{FILE}, size => 0 + $ENV{SIZE}, sha256 => $ENV{SHA},
    });
  ' > "$OUTPUT_DIR/latest.json"

printf 'Version:  %s\n' "$VERSION"
printf 'Zip:      %s (%s bytes)\n' "$ZIP" "$SIZE"
printf 'Manifest: %s\n' "$OUTPUT_DIR/latest.json"
printf 'SHA-256:  %s\n' "$SHA"
printf 'Upload %s, then latest.json, to %s and purge the cache for latest.json.\n' "$FILE" "$UPDATE_URL"
printf 'Installed apps only offer a version newer than their own, so bump the version first.\n'
