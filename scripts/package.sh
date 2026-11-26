#!/bin/bash
set -euo pipefail
VERB_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERB_APP="$VERB_ROOT/release/Verb.app"
VERB_DMG="$VERB_ROOT/release/Verb.dmg"
# VERB_SIGN_IDENTITY names a Developer ID Application certificate in your keychain, and
# VERB_NOTARY_PROFILE the credentials saved with `xcrun notarytool store-credentials`. With both,
# the image is notarized and opens on any Mac without a warning. Without them it is signed ad hoc,
# and macOS blocks the first launch until it is allowed in Privacy & Security.
VERB_IDENTITY="${VERB_SIGN_IDENTITY:-}"
VERB_NOTARY="${VERB_NOTARY_PROFILE:-}"
if [ -n "$VERB_NOTARY" ] && [ -z "$VERB_IDENTITY" ]; then echo "Notarizing needs a Developer ID: set VERB_SIGN_IDENTITY too." >&2; exit 1; fi
if [ ! -x "$VERB_APP/Contents/MacOS/Verb" ]; then echo "Build the app first: bash scripts/build.sh" >&2; exit 1; fi
VERB_WORK="$(mktemp -d -t verb-package)"
trap 'rm -rf "$VERB_WORK"' EXIT
VERB_STAGE="$VERB_WORK/image"
mkdir "$VERB_STAGE"
ditto --noextattr --noqtn "$VERB_APP" "$VERB_STAGE/Verb.app"
# The image leaves bundled speech weights out, so it stays small; the welcome downloads the model.
rm -rf "$VERB_STAGE/Verb.app/Contents/Resources/MLXModels"
# Notarization asks for the hardened runtime and a secure timestamp.
if [ -n "$VERB_IDENTITY" ]; then
  codesign --force --sign "$VERB_IDENTITY" --timestamp --options runtime --entitlements "$VERB_ROOT/Resources/Verb.entitlements" "$VERB_STAGE/Verb.app"
else
  codesign --force --sign - --options runtime --entitlements "$VERB_ROOT/Resources/Verb.entitlements" "$VERB_STAGE/Verb.app"
fi
codesign --verify --deep --strict "$VERB_STAGE/Verb.app"
# Sends $1 to Apple, waits for the verdict and staples the ticket to $2, so it opens offline too.
verb_notarize() {
  local result status id
  result="$(xcrun notarytool submit "$1" --keychain-profile "$VERB_NOTARY" --wait --output-format json)"
  status="$(printf '%s' "$result" | plutil -extract status raw -o - -)"
  if [ "$status" != "Accepted" ]; then
    echo "Apple didn't notarize $(basename "$1"): $status." >&2
    id="$(printf '%s' "$result" | plutil -extract id raw -o - - || true)"
    if [ -n "$id" ]; then xcrun notarytool log "$id" --keychain-profile "$VERB_NOTARY" >&2 || true; fi
    exit 1
  fi
  xcrun stapler staple -q "$2"
}
# The app is notarized on its own as well, so it keeps its ticket once copied out of the image.
if [ -n "$VERB_NOTARY" ]; then
  ditto -c -k --keepParent "$VERB_STAGE/Verb.app" "$VERB_WORK/Verb.zip"
  verb_notarize "$VERB_WORK/Verb.zip" "$VERB_STAGE/Verb.app"
  spctl --assess --type execute "$VERB_STAGE/Verb.app"
fi
# A link to Applications makes installing a single drag.
ln -s /Applications "$VERB_STAGE/Applications"
hdiutil create -quiet -ov -volname Verb -format ULMO -srcfolder "$VERB_STAGE" "$VERB_DMG"
if [ -n "$VERB_NOTARY" ]; then
  codesign --force --sign "$VERB_IDENTITY" --timestamp "$VERB_DMG"
  verb_notarize "$VERB_DMG" "$VERB_DMG"
  spctl --assess --type open --context context:primary-signature "$VERB_DMG"
fi
echo "Packed $VERB_DMG ($(du -h "$VERB_DMG" | cut -f1 | tr -d ' '))"
