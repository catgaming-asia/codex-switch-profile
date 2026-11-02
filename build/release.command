#!/bin/zsh
# Releases an AI Profile update for https://data.catgaming.asia/AiProfile/release/.
#   build/release.command [patch|minor|major|<x.y.z>] [--notes "<text>"]
# Double-click in Finder (patch bump) or run from Terminal. Bumps macos/VERSION,
# builds and packages AIProfile-<version>.zip and latest.json into
# build/release/, deletes build/macos/, commits "Release AI Profile <version>",
# tags app-v<version> locally, asks before pushing, then opens build/release/.
# Nothing is uploaded: upload the zip, then latest.json, and purge the CDN
# cache for latest.json. The work is done by scripts/macos/release-menu-update.sh.
set -euo pipefail

ROOT="${0:A:h:h}"
"$ROOT/scripts/macos/release-menu-update.sh" "$@"
open "$ROOT/build/release"
