#!/bin/zsh
# Copy a validated app to /Applications, preserving the source build.
set -euo pipefail
source_app="${1:?Usage: install.zsh <path to Container.app>}"
source_app="${source_app:A}"
install_root="${CONTAINER_INSTALL_DIR:-/Applications}"
install_root="${install_root:A}"
destination="$install_root/Container.app"
bundle_id=dev.johnstonmatt.container

if [[ ! -d "$source_app" || "$source_app" == "$destination" ]]; then
  print -u2 -- "Choose a built app outside the installation destination."
  exit 1
fi
if [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$source_app/Contents/Info.plist")" != "$bundle_id" ]]; then
  print -u2 -- "The source bundle is not Container."
  exit 1
fi
codesign --verify --strict "$source_app"
if pgrep -x Container >/dev/null; then
  print -u2 -- "Quit Container before installing. Running operations and installed files were not changed."
  exit 1
fi
if [[ -L "$destination" ]]; then
  print -u2 -- "Refusing to replace a symbolic link at $destination."
  exit 1
fi
if [[ -e "$destination" ]] && [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$destination/Contents/Info.plist")" != "$bundle_id" ]]; then
  print -u2 -- "The destination contains a different app."
  exit 1
fi
mkdir -p "$install_root"
install_stage=$(mktemp -d "$install_root/.container-install.XXXXXX")
cleanup() {
  if [[ -d "$install_stage/previous.app" && ! -e "$destination" ]]; then
    mv "$install_stage/previous.app" "$destination"
  fi
  rm -rf -- "$install_stage"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
ditto "$source_app" "$install_stage/Container.app"
codesign --verify --strict "$install_stage/Container.app"
if [[ -e "$destination" ]]; then mv "$destination" "$install_stage/previous.app"; fi
mv "$install_stage/Container.app" "$destination"
print -r -- "Installed $destination"
