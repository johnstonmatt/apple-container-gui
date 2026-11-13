# Container

A native SwiftUI macOS app for [Apple container](https://github.com/apple/container).
The app calls the separately installed `container` CLI. It has no external Swift
package dependencies and does not embed Apple's runtime.

## Features

Container is organized around the things you manage, not the commands that
manage them. The sidebar lists each resource the CLI knows about:

| Group | Resources |
| --- | --- |
| Workloads | Containers, Machines, Clusters (experimental) |
| Resources | Images, Volumes, Networks |
| Environment | Builder, Registries, DNS Domains, System |

Each resource view lists its items with their key details and live state, and
supports search. Select an item to open the inspector: an overview of everything
the CLI reports about it, plus recent logs and raw `inspect` JSON where available.
Right-click an item, or use the inspector, for the things you can do to it, such as
Start, Stop, Open Shell, Tag, Push, Commit to Image, or Delete. The toolbar holds
actions for the whole collection, such as New Container, Pull Image, Build Image,
and Remove Unused. System shows status, versions, disk usage with cleanup actions,
and properties.

Simple actions run immediately; destructive ones ask first. Actions with options
open a form generated from the CLI's own help, prefilled with the selected item.
These forms expose every positional argument and option, with repeated values,
file pickers, working directories, and CLI help. A live preview shows the exact
command that will run, or what is still missing.

Every one of the **67 executable commands advertised by CLI 1.7.1** is reachable
from its resource, and a test enforces this. The catalog refreshes from the
installed executable at launch; use **Reload from Installed CLI** on the System page
after installing or updating plugins. Any new command that no resource view maps
is listed there, so it stays reachable. A bundled catalog is used when the
executable is missing or discovery fails.

Ordinary commands run in the app with live stdout/stderr, exit status, cancellation,
and output copy/save. Streaming logs and stats continue until cancelled. The UI
retains the most recent 2 MB of each stream; temporary output files are removed
when the command ends. Cancelling stops the CLI process and does not roll back
changes already applied by the runtime.

Interactive operations use **Terminal.app**, including TTY/interactive exec and
machine shells. DNS mutations use Terminal with `sudo` for administrator
confirmation. Terminal sessions are managed by Terminal, so refresh the workspace
after they finish. Registry login can run inside the app: enable `--username` and
enter the password/token in the secure field. The password is sent through stdin,
not command arguments or a disk file.

Command arguments are passed directly without a shell. Repeated positional values
and additional options support quotes and backslash escaping, but not shell
expansion. Terminal launch scripts use zsh and quote every argument literally.
For advanced run/create configuration, choose **More Options…** in the New Container
sheet; it carries your settings into the full `run` form.
For archive export/save/load in the app, choose an output/input file.

## Requirements

- Apple silicon Mac with macOS 26 for the container runtime
- Apple's `container` CLI in `/usr/local/bin`, `/opt/homebrew/bin`, or PATH
- Swift 6 / Xcode command-line tools to build

### Use a different container CLI

To run a CLI installed somewhere else, eg. your own build of `apple/container`, choose it
under **Container CLI** on the System page. Container then starts, stops, and runs everything
with that CLI and reloads its command catalog from it, so forms show any options your build
adds. The same setting from a terminal:

```zsh
defaults write dev.johnstonmatt.container containerExecutable ~/.local/opt/container/bin/container
defaults delete dev.johnstonmatt.container containerExecutable   # find it automatically again
```

`CONTAINER_CLI_PATH` overrides both, which is what `apple/container`'s own integration tests
read. If the chosen CLI goes missing, Container says so instead of falling back to another
install, because that install's services may not be the ones you're running.

## Build and run

```zsh
swift test
zsh scripts/build-app.zsh
open "dist/Container.app"
```

The zsh build script builds the release executable, copies the catalog resource
bundle and the app icon from `Assets/`, copies `Resources/Info.plist`, signs the
app, and verifies its signature and embedded catalog before replacing the previous
build. The output is `dist/Container.app`, with bundle identifier
`dev.johnstonmatt.container`. Local builds use ad-hoc signing; set
`CODESIGN_IDENTITY` to a Developer ID Application identity for hardened runtime
and timestamped signing.
You can also open `Package.swift` in Xcode or use `swift run Container`.
Local builds are not notarized. The release workflow notarizes published builds.

To build and install in `/Applications`, quit the app and run:

```zsh
./install-app
```

To install an existing bundle, use `zsh scripts/install.zsh dist/Container.app`.
Set `CONTAINER_INSTALL_DIR` to choose another installation directory. Installation
preserves the source build, stages the replacement, and restores the previous app
if replacement fails. It refuses to overwrite an unrelated app or update while
Container is running. Apple's `container` CLI remains separately installed.

## CI and releases

This setup follows the build/release pipeline in `~/dev/johnstonmatt/lockin`,
adapted to Container and zsh.

- CI builds, runs the offline Swift tests, packages the app, verifies its signature,
  and tests installation/replacement and a release archive in a temporary folder.
- `release-please` opens release PRs from conventional commits on `main`. Merging
  a release PR updates the two marked version fields in `Resources/Info.plist`,
  writes `CHANGELOG.md`, and creates the release tag.
- The release job tests that exact tag, imports a Developer ID certificate into a
  temporary keychain, builds with hardened runtime and a secure timestamp,
  notarizes and staples the app, checks Gatekeeper, and uploads
  `Container-v<VERSION>-macos-arm64.zip`. Signing material is cleaned up even if
  the job fails. Apple silicon runners are required for releases.
- Like Lock In, the release-please `go` strategy avoids generating an unrelated
  version file; the generic updater maintains the plist. Initial version is
  `0.1.0`. Before 1.0, breaking changes bump the minor version. Use a
  `Release-As: 1.0.0` commit footer to request 1.0 deliberately.

Run the interactive setup once from your Mac:

```zsh
./scripts/setup-release.zsh
```

It requires `gh` authentication, Xcode command-line tools, a Developer ID
Application `.p12` containing its private key, and an App Store Connect Team API
`.p8` key. It validates the certificate in a temporary keychain and checks the
notarization credentials with Apple, then asks before writing these repository
secrets:

| Secret | Value |
| --- | --- |
| `MACOS_CERTIFICATE` | Base64-encoded Developer ID `.p12` |
| `MACOS_CERTIFICATE_PASSWORD` | Export password (may be empty) |
| `MACOS_SIGN_IDENTITY` | Developer ID Application identity |
| `APPLE_API_KEY` | Base64-encoded notarization `.p8` |
| `APPLE_API_KEY_ID` | API key ID |
| `APPLE_API_ISSUER` | Team issuer UUID |

The release workflow checks required secrets before creating a release. Optionally
set `RELEASE_PLEASE_TOKEN` to a fine-grained token for this repository with Contents,
Pull requests, and Issues read/write access, so release-please PRs can trigger CI.
Otherwise it uses `GITHUB_TOKEN`; enable Actions to create pull requests in the
repository's Actions settings. Credentials are not copied from Lock In.

Run packaging checks locally after building:

```zsh
zsh scripts/test-build.zsh
```

Use **Start Container System** if the service is stopped. On first use this also
downloads and installs the recommended Linux kernel. Refresh inventories with ⌘R.

Startup and refresh explicitly check the CLI, the service's structured status,
and the default Linux kernel in the data directory reported by the running service.
A running service alone is not treated as ready: missing, empty, or broken-link
kernels show **Install Linux Kernel**. Missing CLI installations show a download
link, and stopped services show **Start Container System**. Setup only runs when
you click its action; after it finishes the checks run again. **Check Again** also
detects dependencies installed outside the app. Permission errors and unsupported
status formats show the error instead of being mislabelled as missing kernels.
These checks establish availability, not whether a kernel can successfully boot.

## Tests

```zsh
# Catalog coverage, command/option construction, validation, quoting,
# subprocess output, failure, streaming, stdin, timeout, and cancellation.
swift test

# Also test the installed CLI command tree, read-only inventories, and
# a temporary container: run, list, exec, logs, inspect, stats, stop/start/delete.
RUN_CONTAINER_INTEGRATION_TESTS=1 swift test
```

Live tests require the container service to be running and may pull `alpine:latest`.
They create a uniquely named `container-test-*` container and clean it up,
including on failure. The downloaded image is kept. They do not modify existing
containers or publish images. Registry credentials, remote pushes, privileged DNS,
Kubernetes creation, and every possible option combination require their own
configured environment and are not exercised by the live suite.

Help snapshots in `Sources/Container/Resources/commands.json` were captured
from Apple container CLI 1.7.1. They describe the installed version, not a guarantee
that future versions or optional plugins retain the same operations.

This is an independent project, not an Apple product.
