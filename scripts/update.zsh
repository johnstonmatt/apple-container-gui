#!/bin/zsh
# Run from a private temporary directory, independent of the app being replaced.
set -u
parent_pid="$1"
work="$2"
destination="$3"
result="$4"
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
trap 'rm -rf -- "$work"' EXIT
# A refused/cancelled quit must never replace a running app.
for attempt in {1..60}; do
  if ! kill -0 "$parent_pid" 2>/dev/null; then break; fi
  sleep 1
done
if kill -0 "$parent_pid" 2>/dev/null; then
  print -r -- 'Update cancelled because Container did not quit. Try again.' > "$result"
  exit 1
fi
if CONTAINER_INSTALL_DIR="${destination:h}" /bin/zsh "$work/Container.app/Contents/Resources/install.zsh" "$work/Container.app" > "$work/install.log" 2>&1; then
  print -r -- 'Container was updated successfully.' > "$result"
else
  { print -r -- 'Update failed. The previous app was preserved. Installer output:'; cat "$work/install.log"; } > "$result"
fi
/usr/bin/open "$destination"
