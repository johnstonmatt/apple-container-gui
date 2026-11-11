#!/bin/zsh
# Ad-hoc signing locally; Developer ID + hardened runtime for releases.
set -euo pipefail
cd "${0:A:h}/.."
signing_identity="${CODESIGN_IDENTITY:--}"
swift build -c release
bin_dir="$(swift build -c release --show-bin-path)"
zsh scripts/build-icon.zsh
mkdir -p dist
build_stage=$(mktemp -d "$PWD/dist/.build-app.XXXXXX")
trap 'rm -rf -- "$build_stage"' EXIT
app="$build_stage/Container.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_dir/Container" "$app/Contents/MacOS/Container"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp Assets/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
cp scripts/install.zsh "$app/Contents/Resources/install.zsh"
# Copy this target's resource bundle only, not stale bundles from prior builds.
cp -R "$bin_dir/Container_Container.bundle" "$app/Contents/Resources/"
# Both SwiftPM layouts are supported, but the catalog must actually be shipped.
catalog_bundle="$app/Contents/Resources/Container_Container.bundle"
if [[ ! -f "$catalog_bundle/commands.json" && ! -f "$catalog_bundle/Contents/Resources/commands.json" ]]; then
  print -u2 -- 'Build is missing the command catalog resource bundle.'
  exit 1
fi
plutil -lint "$app/Contents/Info.plist"
sign_flags=(--force --sign "$signing_identity")
if [[ "$signing_identity" != "-" ]]; then
  sign_flags+=(--options runtime --timestamp)
fi
codesign "${sign_flags[@]}" "$app"
codesign --verify --strict --verbose=2 "$app"
"$app/Contents/MacOS/Container" --check-catalog
# Replace the generated bundle only after validation succeeds.
rm -rf -- dist/Container.app
mv "$app" dist/Container.app
print -r -- "Built dist/Container.app"
