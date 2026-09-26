#!/bin/bash
set -euo pipefail
# Physical paths, so the check for a running Verb compares like with like.
VERB_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
VERB_SCRATCH="${VERB_BUILD_DIR:-$VERB_ROOT/.build}"
VERB_MODELS="${VERB_MODEL_SOURCE:-}"
VERB_APP="$VERB_ROOT/release/Verb.app"
# Replacing the executable of a running app makes macOS kill it (code signature invalid).
# Each running Verb's executable is compared with this bundle's as an exact path, symlinks
# resolved, so a symlinked folder or "(" and "+" in its name can't hide it.
verb_refuse_if_running() {
  local pid exe dir
  for pid in $(/usr/bin/pgrep -x Verb || true); do
    # A UTF-8 locale, or ps escapes accented letters in the path.
    exe="$(LC_ALL=en_US.UTF-8 /bin/ps -ww -o comm= -p "$pid" || true)"
    case "$exe" in
      "") continue ;;
      /*) ;;
      *) exe="$(LC_ALL=en_US.UTF-8 /usr/sbin/lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' || true)/$exe" ;;
    esac
    dir="$(cd "$(dirname "$exe")" 2>/dev/null && pwd -P)" || continue
    if [ "$dir/$(basename "$exe")" = "$VERB_APP/Contents/MacOS/Verb" ]; then
      echo "Quit Verb before rebuilding it: macOS stops an app whose files change while it runs." >&2; exit 1
    fi
  done
}
verb_refuse_if_running
swift build --package-path "$VERB_ROOT" --scratch-path "$VERB_SCRATCH" -c release --product Verb
VERB_BIN="$(swift build --package-path "$VERB_ROOT" --scratch-path "$VERB_SCRATCH" -c release --show-bin-path)"
# Verb may have been opened while it built.
verb_refuse_if_running
mkdir -p "$VERB_APP/Contents/MacOS" "$VERB_APP/Contents/Resources"
cp "$VERB_BIN/Verb" "$VERB_APP/Contents/MacOS/Verb"
cp "$VERB_ROOT/Resources/Info.plist" "$VERB_APP/Contents/Info.plist"
cp "$VERB_ROOT/Resources/Verb.icns" "$VERB_APP/Contents/Resources/"
for VERB_LPROJ in "$VERB_ROOT"/Resources/*.lproj; do ditto "$VERB_LPROJ" "$VERB_APP/Contents/Resources/$(basename "$VERB_LPROJ")"; done
# SwiftPM's MLX Metal shader bundle must travel with the application.
for VERB_RESOURCE in "$VERB_BIN"/*.bundle; do
  case "$VERB_RESOURCE" in *Tests.bundle) continue ;; esac
  if [ -d "$VERB_RESOURCE" ]; then ditto "$VERB_RESOURCE" "$VERB_APP/Contents/Resources/$(basename "$VERB_RESOURCE")"; fi
done
test -f "$VERB_APP/Contents/Resources/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib"
# Bundled speech weights stay from one build to the next; VERB_MODEL_SOURCE adds or replaces them.
# Without any, the app downloads the speech model on first launch.
if [ -n "$VERB_MODELS" ]; then
  ditto "$VERB_MODELS" "$VERB_APP/Contents/Resources/MLXModels"
fi
# ditto keeps the source's permissions, and a downloaded model is private to its owner. Every
# account that can open the app must be able to read the weights inside it.
if [ -d "$VERB_APP/Contents/Resources/MLXModels" ]; then chmod -R a+rX "$VERB_APP/Contents/Resources/MLXModels"; fi
# The licenses are copied fresh, so a notice removed from the source leaves the app too.
rm -rf "$VERB_APP/Contents/Resources/Licenses"
if [ -d "$VERB_ROOT/Resources/Licenses" ]; then ditto "$VERB_ROOT/Resources/Licenses" "$VERB_APP/Contents/Resources/Licenses"; fi
codesign --force --sign - --options runtime --entitlements "$VERB_ROOT/Resources/Verb.entitlements" "$VERB_APP"
codesign --verify --deep --strict "$VERB_APP"
echo "Built $VERB_APP"
