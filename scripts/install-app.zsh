#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
zsh scripts/build-app.zsh
exec /bin/zsh scripts/install.zsh dist/Container.app
