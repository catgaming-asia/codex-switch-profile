#!/bin/zsh
# Builds AI Profile.app into build/macos/ and shows it in Finder.
#   build/build-app.command
# Double-click in Finder or run from Terminal. Nothing is installed, packaged
# or committed; build/release.command packages an update instead. The work is
# done by scripts/macos/build-menu-app.sh.
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"

APP_DIR="$ROOT/build/macos"
MENU_APP_BUILD_DIR="$APP_DIR" "$ROOT/scripts/macos/build-menu-app.sh"
open -R "$APP_DIR/AI Profile.app"
