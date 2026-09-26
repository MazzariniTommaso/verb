#!/bin/bash
set -euo pipefail
VERB_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERB_APP="$VERB_ROOT/release/Verb.app"
VERB_DMG="$VERB_ROOT/release/Verb.dmg"
if [ ! -x "$VERB_APP/Contents/MacOS/Verb" ]; then echo "Build the app first: bash scripts/build.sh" >&2; exit 1; fi
VERB_STAGE="$(mktemp -d -t verb-package)"
trap 'rm -rf "$VERB_STAGE"' EXIT
ditto --noextattr --noqtn "$VERB_APP" "$VERB_STAGE/Verb.app"
# The image leaves bundled speech weights out, so it stays small; the welcome downloads the model.
if [ -d "$VERB_STAGE/Verb.app/Contents/Resources/MLXModels" ]; then
  rm -rf "$VERB_STAGE/Verb.app/Contents/Resources/MLXModels"
  codesign --force --sign - --options runtime --entitlements "$VERB_ROOT/Resources/Verb.entitlements" "$VERB_STAGE/Verb.app"
fi
codesign --verify --deep --strict "$VERB_STAGE/Verb.app"
# A link to Applications makes installing a single drag.
ln -s /Applications "$VERB_STAGE/Applications"
hdiutil create -quiet -ov -volname Verb -format ULMO -srcfolder "$VERB_STAGE" "$VERB_DMG"
echo "Packed $VERB_DMG ($(du -h "$VERB_DMG" | cut -f1 | tr -d ' '))"
