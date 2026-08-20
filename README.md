# Ladybird Debian Build Script

A small wrapper script I use personally to build and run [Ladybird](https://github.com/LadybirdBrowser/ladybird) on Debian.

Ladybird currently requires Qt 6.9 or newer, while Debian 13 ships Qt 6.8. Instead of installing a separate Qt SDK, this script modifies Ladybird's existing `vcpkg.json` so that the Qt version pinned by Ladybird can also be built through vcpkg on Linux.

## Why?

Because Debian gets no love, apparently.

## What it does

On Debian, the script:

- Detects Debian using `/etc/os-release`.
- Checks that `jq` is available before modifying `vcpkg.json`.
- Checks that `libwayland-dev` is installed, as it is required to build Qt with Wayland support through vcpkg.
- Enables `qtbase` from vcpkg on Linux.
- Enables EGL support in `qtbase`.
- Enables `qtpositioning` from vcpkg on Linux.
- Adds `qtwayland`, which is required by Ladybird's Qt frontend.
- Uses the Qt version already pinned by Ladybird instead of hardcoding a separate version.
- Automatically reapplies the changes if an upstream `git pull` restores the original `vcpkg.json`.
- Optionally keeps Rust and Cargo data inside the Ladybird repository instead of using the user's `~/.rustup` and `~/.cargo`.
- Runs Ladybird using the normal `Meta/ladybird.py run` workflow.
- Shows a desktop notification on failure if `notify-send` is available.

If the required vcpkg modifications are already present, the script leaves `vcpkg.json` alone and starts Ladybird normally.

## Requirements

Install Ladybird's normal Debian build dependencies first.

The script additionally requires:

```bash
sudo apt install jq libwayland-dev
```

It does not install packages automatically. If either dependency is missing, it prints the required command and exits.

## Usage

Copy the `build` script into the root directory of your Ladybird repository.


Make it executable:

```bash
chmod +x build
```

Then simply run:

```bash
./build
```

The first run may take significantly longer because vcpkg has to build Qt locally. Subsequent builds remain incremental.

## Local Rust

By default, the script uses your normal Rust environment.

If you want to keep Rust toolchain and Cargo files inside the repository instead, set:

```bash
LOCAL_RUST=true
```

This will use:

```text
.rustup-home/
.cargo-home/
```

inside the Ladybird repository instead of your normal `~/.rustup` and `~/.cargo`.
