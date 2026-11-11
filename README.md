# Container Desk

A native SwiftUI macOS app for [Apple container](https://github.com/apple/container).
The app calls the separately installed `container` CLI. It has no external Swift
package dependencies and does not embed Apple's runtime.

## Features

Container Desk is organized around the things you manage, not the commands that
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

## Build and run

```zsh
swift test
zsh scripts/build-app.zsh
open "dist/Container Desk.app"
```

The zsh build script builds the release executable, copies the catalog resource
bundle and the app icon from `Assets/`, ad-hoc signs the app, and checks the catalog
from inside the finished app.
You can also open `Package.swift` in Xcode or use `swift run ContainerDesk`.
The app is not notarized.

Use **Start Container System** if the service is stopped. On first use this also
downloads and installs the recommended Linux kernel. Refresh inventories with ⌘R.

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
They create a uniquely named `containerdesk-test-*` container and clean it up,
including on failure. The downloaded image is kept. They do not modify existing
containers or publish images. Registry credentials, remote pushes, privileged DNS,
Kubernetes creation, and every possible option combination require their own
configured environment and are not exercised by the live suite.

Help snapshots in `Sources/ContainerDesk/Resources/commands.json` were captured
from Apple container CLI 1.7.1. They describe the installed version, not a guarantee
that future versions or optional plugins retain the same operations.

This is an independent project, not an Apple product.
