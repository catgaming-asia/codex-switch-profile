#!/usr/bin/env bash
# Releases an AI Profile app update, like Termus's release.command:
#   scripts/macos/release-menu-update.sh [patch|minor|major|<x.y.z>] [--notes "<text>"]
# Bumps macos/VERSION (patch by default), builds and packages the update into
# build/release/ (AIProfile-<version>.zip + latest.json), deletes the
# build/macos/ working folder, then commits "Release AI Profile <version>" and
# tags app-v<version> locally. Packaging happens before the commit, so a failed
# build leaves macos/VERSION unchanged. Nothing is uploaded; on a terminal it
# asks before pushing the commit and tag.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUTPUT_DIR="${MENU_UPDATE_OUTPUT_DIR:-$ROOT_DIR/build/release}"
WORK_DIR="${MENU_APP_BUILD_DIR:-$ROOT_DIR/build/macos}"
VERSION_FILE="$ROOT_DIR/macos/VERSION"
UPDATE_URL="https://data.catgaming.asia/AiProfile/release/"

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

usage() {
  printf 'Usage: scripts/macos/release-menu-update.sh [patch|minor|major|<x.y.z>] [--notes "<text>"]\n'
}

BUMP="patch"
NOTES=""
HAVE_NOTES=0
while (($# > 0)); do
  case "$1" in
    --notes)
      (($# >= 2)) || die "--notes needs text"
      NOTES="$2"
      HAVE_NOTES=1
      shift 2
      ;;
    --notes=*)
      NOTES="${1#--notes=}"
      HAVE_NOTES=1
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    patch | minor | major) BUMP="$1"; shift ;;
    [0-9]*.[0-9]*.[0-9]*) BUMP="$1"; shift ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
done

cd "$ROOT_DIR"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "run this from a git checkout"
# Only the app's own sources must be clean; docs or other work may be in progress.
[[ -z "$(git status --porcelain -- macos scripts/macos build)" ]] \
  || die "macos/, scripts/macos/ or build/*.command have uncommitted changes. Commit or discard them first."
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
[[ "$BRANCH" == "main" ]] || die "release from main only (current branch: $BRANCH)."

CURRENT="$(tr -d '[:space:]' < "$VERSION_FILE")"
[[ "$CURRENT" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || die "macos/VERSION must be x.y.z (found: $CURRENT)."
MAJOR="${BASH_REMATCH[1]}"
MINOR="${BASH_REMATCH[2]}"
PATCH="${BASH_REMATCH[3]}"
case "$BUMP" in
  patch) NEW="$MAJOR.$MINOR.$((PATCH + 1))" ;;
  minor) NEW="$MAJOR.$((MINOR + 1)).0" ;;
  major) NEW="$((MAJOR + 1)).0.0" ;;
  *)
    [[ "$BUMP" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "the version must be x.y.z (got: $BUMP)."
    NEW="$BUMP"
    ;;
esac
TAG="app-v$NEW"
! git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || die "tag $TAG already exists."

# Notes default to the app commits since the previous app release.
PREV_TAG="$(git describe --tags --abbrev=0 --match 'app-v[0-9]*' 2>/dev/null || true)"
if ((!HAVE_NOTES)); then
  if [[ -n "$PREV_TAG" ]]; then
    NOTES="$(git log --no-merges --pretty='- %s' "$PREV_TAG..HEAD" -- macos scripts/macos)"
  else
    NOTES="$(git log --no-merges --pretty='- %s' -n 20 -- macos scripts/macos)"
  fi
  [[ -n "$NOTES" ]] || NOTES="- Maintenance release"
fi

printf '%s\n' "$NEW" > "$VERSION_FILE"
if ! MENU_UPDATE_OUTPUT_DIR="$OUTPUT_DIR" MENU_APP_BUILD_DIR="$WORK_DIR" \
  "$ROOT_DIR/scripts/macos/build-menu-update.sh" --notes "$NOTES"; then
  printf '%s\n' "$CURRENT" > "$VERSION_FILE"
  rm -rf -- "$WORK_DIR"
  die "packaging failed; macos/VERSION is back to $CURRENT and nothing was committed."
fi
# Only the release is kept; build/build-app.command recreates build/macos/ when needed.
rm -rf -- "$WORK_DIR"

git add -- "$VERSION_FILE"
git commit -q -m "Release AI Profile $NEW" -- "$VERSION_FILE"
git tag -a "$TAG" -m "AI Profile $NEW"

printf '\nReleased AI Profile %s (previous %s%s); committed and tagged %s locally.\n' \
  "$NEW" "$CURRENT" "${PREV_TAG:+, last tag $PREV_TAG}" "$TAG"
printf 'Notes:\n'
printf '%s\n' "$NOTES" | sed 's/^/  /'
printf '\nUpload %s, then latest.json, from %s to %s and purge the cache for latest.json.\n' \
  "AIProfile-$NEW.zip" "$OUTPUT_DIR" "$UPDATE_URL"

if [[ -t 0 ]]; then
  printf 'Push the commit and tag to origin? [y/N] '
  read -r ANSWER || ANSWER=""
  if [[ "$ANSWER" == [yY] || "$ANSWER" == [yY][eE][sS] ]]; then
    git push origin main "$TAG"
    exit 0
  fi
fi
printf 'Not pushed. Later: git push origin main %s\n' "$TAG"
