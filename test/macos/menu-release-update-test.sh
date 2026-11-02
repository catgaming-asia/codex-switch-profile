#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT_DIR/test/lib/assertions.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT HUP INT TERM
REPO="$TMP_DIR/repository with spaces"
mkdir -p "$REPO/scripts/macos" "$REPO/macos" "$REPO/build"
cp "$ROOT_DIR/scripts/macos/release-menu-update.sh" "$REPO/scripts/macos/"
printf '1.3.0\n' > "$REPO/macos/VERSION"
printf '/build/*\n!/build/*.command\n' > "$REPO/.gitignore"

# Exercise the real release script; only building and packaging are faked.
cat > "$REPO/scripts/macos/build-menu-update.sh" <<'PACKAGER'
#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
[[ -z "${FAIL_PACKAGING:-}" ]] || exit 1
version="$(tr -d '[:space:]' < "$root/macos/VERSION")"
mkdir -p "$MENU_APP_BUILD_DIR/AI Profile.app" "$MENU_UPDATE_OUTPUT_DIR"
printf 'zip' > "$MENU_UPDATE_OUTPUT_DIR/AIProfile-$version.zip"
printf '%s\n' "$2" > "$MENU_UPDATE_OUTPUT_DIR/notes"
printf '{"version":"%s"}\n' "$version" > "$MENU_UPDATE_OUTPUT_DIR/latest.json"
PACKAGER
chmod 755 "$REPO/scripts/macos/build-menu-update.sh"

git_in() { git -C "$REPO" "$@"; }
git_in init -q -b main
git_in config user.name Test
git_in config user.email test@example.com
git_in config commit.gpgsign false
git_in config tag.gpgSign false
git_in add -A
git_in commit -q -m "initial"
git_in tag -a app-v1.3.0 -m "AI Profile 1.3.0"
printf 'change\n' > "$REPO/macos/feature.txt"
git_in add -A
git_in commit -q -m "feat(macos): new thing"
printf 'docs\n' > "$REPO/README.md"
git_in add -A
git_in commit -q -m "docs: unrelated"

release() { (cd "$REPO" && bash scripts/macos/release-menu-update.sh "$@" < /dev/null); }

# A patch release with notes taken from the app commits since the last app tag.
output="$(release)"
assert_equals 'patch bump' '1.3.1' "$(tr -d '[:space:]' < "$REPO/macos/VERSION")"
assert_equals 'release commit' 'Release AI Profile 1.3.1' "$(git_in log -1 --pretty=%s)"
assert_equals 'release commit touches only VERSION' 'macos/VERSION' "$(git_in show --pretty= --name-only HEAD)"
git_in rev-parse -q --verify refs/tags/app-v1.3.1 >/dev/null || fail 'the release is tagged app-v1.3.1'
assert_equals 'notes list app commits only' '- feat(macos): new thing' "$(< "$REPO/build/release/notes")"
[[ -f "$REPO/build/release/AIProfile-1.3.1.zip" ]] || fail 'the package lands in build/release'
[[ ! -e "$REPO/build/macos" ]] || fail 'build/macos is deleted after packaging'
assert_contains "$output" 'Not pushed. Later: git push origin main app-v1.3.1' 'no push without a terminal'
assert_contains "$output" 'https://data.catgaming.asia/AiProfile/release/' 'upload destination'

# Explicit version and notes.
release 2.0.0 --notes 'Big one' >/dev/null
assert_equals 'explicit version' '2.0.0' "$(tr -d '[:space:]' < "$REPO/macos/VERSION")"
assert_equals 'explicit notes' 'Big one' "$(< "$REPO/build/release/notes")"

# Refusals leave everything as it was.
printf 'dirty\n' >> "$REPO/macos/feature.txt"
if release > "$TMP_DIR/dirty.log" 2>&1; then fail 'uncommitted app changes must block a release'; fi
assert_contains "$(< "$TMP_DIR/dirty.log")" 'uncommitted changes' 'dirty tree message'
git_in checkout -q -- macos/feature.txt
if release 1.3.1 > "$TMP_DIR/tag.log" 2>&1; then fail 'an existing tag must block a release'; fi
assert_contains "$(< "$TMP_DIR/tag.log")" 'tag app-v1.3.1 already exists' 'existing tag message'

before="$(git_in rev-parse HEAD)"
if (cd "$REPO" && FAIL_PACKAGING=1 bash scripts/macos/release-menu-update.sh < /dev/null) > "$TMP_DIR/fail.log" 2>&1; then
  fail 'a failed build must fail the release'
fi
assert_equals 'failed build restores VERSION' '2.0.0' "$(tr -d '[:space:]' < "$REPO/macos/VERSION")"
assert_equals 'failed build commits nothing' "$before" "$(git_in rev-parse HEAD)"
! git_in rev-parse -q --verify refs/tags/app-v2.0.1 >/dev/null || fail 'a failed build creates no tag'
assert_equals 'failed build leaves a clean tree' '' "$(git_in status --porcelain)"

git_in checkout -q -b feature
if release > "$TMP_DIR/branch.log" 2>&1; then fail 'releases come from main only'; fi
assert_contains "$(< "$TMP_DIR/branch.log")" 'release from main only' 'branch message'

printf 'Menu app release tests passed.\n'
