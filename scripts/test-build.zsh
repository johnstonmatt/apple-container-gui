#!/bin/zsh
# Exercise the real signed bundle and installer, entirely in a temporary folder.
set -euo pipefail
cd "${0:A:h}/.."
for script in scripts/*.zsh install-app; do zsh -n "$script"; done
app="$PWD/dist/Container.app"
plist="$app/Contents/Info.plist"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist")" == dev.johnstonmatt.container ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleName' "$plist")" == Container ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$plist")" == Container ]]
cmp Resources/Info.plist "$plist"
cmp scripts/install.zsh "$app/Contents/Resources/install.zsh"
[[ -s "$app/Contents/Resources/AppIcon.icns" ]]
codesign --verify --deep --strict "$app"
"$app/Contents/MacOS/Container" --check-catalog

test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT
mkdir -p "$test_root/bin" "$test_root/Applications"
# Isolate the process check so this test works even while the developer uses the app.
cat > "$test_root/bin/pgrep" <<'MOCK'
#!/bin/zsh
[[ "${CONTAINER_TEST_RUNNING:-0}" == 1 ]]
MOCK
chmod +x "$test_root/bin/pgrep"
export PATH="$test_root/bin:$PATH"
export CONTAINER_INSTALL_DIR="$test_root/Applications"
zsh scripts/install.zsh "$app"
[[ -x "$app/Contents/MacOS/Container" ]] # Source build is preserved.
[[ -x "$CONTAINER_INSTALL_DIR/Container.app/Contents/MacOS/Container" ]]
zsh scripts/install.zsh "$app" # Replace an installed copy.
codesign --verify --strict "$CONTAINER_INSTALL_DIR/Container.app"

export CONTAINER_TEST_RUNNING=1
if zsh scripts/install.zsh "$app" > "$test_root/refusal.log" 2>&1; then
  print -u2 'Installer should refuse while Container is running.'; exit 1
fi
unset CONTAINER_TEST_RUNNING
codesign --verify --strict "$CONTAINER_INSTALL_DIR/Container.app"
if zsh scripts/install.zsh "$CONTAINER_INSTALL_DIR/Container.app" > "$test_root/refusal.log" 2>&1; then
  print -u2 'Installer should refuse to install the destination onto itself.'; exit 1
fi

# Reject a bundle whose metadata was changed after signing.
ditto "$app" "$test_root/invalid.app"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier example.unrelated.app' "$test_root/invalid.app/Contents/Info.plist"
if zsh scripts/install.zsh "$test_root/invalid.app" > "$test_root/refusal.log" 2>&1; then
  print -u2 'Installer accepted the wrong bundle identifier.'; exit 1
fi
codesign --verify --strict "$CONTAINER_INSTALL_DIR/Container.app"

# Exercise the same archive format used by the release workflow.
ditto -c -k --keepParent "$app" "$test_root/Container.zip"
ditto -xk "$test_root/Container.zip" "$test_root/unpacked"
codesign --verify --deep --strict "$test_root/unpacked/Container.app"
"$test_root/unpacked/Container.app/Contents/MacOS/Container" --check-catalog

# Missing resources must produce a catchable error, never a Swift fatalError.
ditto "$app" "$test_root/missing-catalog.app"
rm -rf -- "$test_root/missing-catalog.app/Contents/Resources/ContainerDesk_ContainerDesk.bundle"
codesign --force --sign - "$test_root/missing-catalog.app"
catalog_exit=0
"$test_root/missing-catalog.app/Contents/MacOS/Container" --check-catalog > "$test_root/missing.log" 2>&1 || catalog_exit=$?
[[ "$catalog_exit" == 1 ]]
grep -q 'bundled command catalog is missing' "$test_root/missing.log"
print -- 'Packaging, archive, and installer checks passed.'
