#!/bin/zsh
# Packages an AI Profile update for https://data.catgaming.asia/AiProfile/release/.
#   build/release.command [--notes "<text>"]
# Double-click in Finder or run from Terminal. Builds the app, writes
# AIProfile-<version>.zip and latest.json into build/release/, deletes the
# build/macos/ working folder, then opens build/release/. Nothing is uploaded or committed: upload the zip, then latest.json,
# and purge the CDN cache for latest.json. The work is done by
# scripts/macos/build-menu-update.sh, which the test suite covers.
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"

NOTES=""
HAVE_NOTES=0
while (( $# > 0 )); do
    case "$1" in
        --notes) (( $# >= 2 )) || { echo "--notes needs text" >&2; exit 2; }; NOTES="$2"; HAVE_NOTES=1; shift 2 ;;
        --notes=*) NOTES="${1#--notes=}"; HAVE_NOTES=1; shift ;;
        -h|--help) echo "Usage: build/release.command [--notes \"<text>\"]"; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; exit 2 ;;
    esac
done

# Without --notes, list the commits since the last version tag.
if (( ! HAVE_NOTES )); then
    PREV_TAG="$(git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null || true)"
    if [[ -n "$PREV_TAG" ]]; then
        NOTES="$(git log --no-merges --pretty='- %s' "$PREV_TAG..HEAD" -- macos scripts/macos)"
    else
        NOTES="$(git log --no-merges --pretty='- %s' -n 20 -- macos scripts/macos)"
    fi
    [[ -n "$NOTES" ]] || NOTES="- Maintenance release"
fi

OUT="$ROOT/build/release"
WORK="$ROOT/build/macos"
MENU_UPDATE_OUTPUT_DIR="$OUT" MENU_APP_BUILD_DIR="$WORK" "$ROOT/scripts/macos/build-menu-update.sh" --notes "$NOTES"
# Only the release is kept; build/build-app.command recreates build/macos/ when needed.
rm -rf -- "$WORK"
echo
echo "Notes:"
print -r -- "$NOTES" | sed 's/^/  /'
open "$OUT"
