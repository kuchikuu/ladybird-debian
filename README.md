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

Ladybird requires a Rust toolchain to build.

If you prefer to keep Rust separate from your regular user environment, for example if you do not otherwise use Rust on your system, this script can use a Rust installation stored locally inside the Ladybird repository.

Set:

```bash
LOCAL_RUST=true
```

Then install Rust locally from the root of the Ladybird repository:

```bash
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | \
RUSTUP_HOME="$PWD/.rustup-home" \
CARGO_HOME="$PWD/.cargo-home" \
sh -s -- --no-modify-path
```

This installs Rustup and the Rust toolchain into `.rustup-home/` and `.cargo-home/` inside the Ladybird repository without modifying your regular `PATH`, `~/.rustup`, or `~/.cargo`.

Once installed, simply use:

```bash
./build
```

The script will automatically use the local Rust installation whenever `LOCAL_RUST=true`.

Leave `LOCAL_RUST=false` to use your regular Rust environment instead.
