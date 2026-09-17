# Ladybird Debian Build Script

A small wrapper script I use personally to build and run [Ladybird](https://github.com/LadybirdBrowser/ladybird) on Debian.

Ladybird currently requires Qt 6.9 or newer, while Debian 13 ships Qt 6.8. Instead of installing a separate Qt SDK, this script modifies Ladybird's existing `vcpkg.json` so that the Qt version pinned by Ladybird can also be built through vcpkg on Linux.

## Why?

Because Debian gets no love, apparently.

## What it does

The script:

- Checks that the system uses APT.
- Detects vanilla Debian using `/etc/os-release` and displays a one-time warning on Debian-based derivatives.
- Checks for the required Debian packages and provides a ready-to-use installation command if any are missing.
- Detects GrapheneOS hardened_malloc and displays a one-time compatibility warning if it is preloaded.
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

The script automatically checks for the required Debian packages before starting the build.

If any packages are missing, it will list them and print a ready-to-use `apt` command to install all missing dependencies. The script does not install any packages automatically.

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

## CPU target

By default, the script keeps Ladybird's normal native CPU optimization:

```bash
PORTABLE_BUILD=false
```

This uses:

```text
-march=native
```

and is intended for local builds on the same machine.

If you want a more portable x86_64 build, for example before creating an AppImage for use on other computers, set:

```bash
PORTABLE_BUILD=true
```

The script will then configure Ladybird with:

```text
-march=x86-64
-mtune=generic
```

The setting is stored directly in the `build` script, so subsequent builds continue using the selected CPU target until you change it again.

Changing between native and portable mode changes the compiler command line, so Ladybird/Lagom will need to be recompiled. vcpkg dependencies are handled separately and normally remain incremental.

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


## Experimental AppImage

The repository also contains a script for creating a Ladybird AppImage from an existing local build.

This is separate from the normal build process. Build Ladybird first, then run the AppImage packaging script.

For an AppImage intended to run on other x86_64 machines, use a portable Ladybird build first:

```bash
PORTABLE_BUILD=true
./build
```

Then copy `make-ladybird-appimage.sh` into the root directory of the Ladybird repository and make it executable:

```bash
chmod +x make-ladybird-appimage.sh
```

Run:

```bash
./make-ladybird-appimage.sh
```

The packaging script automatically detects the CPU build type from `Build/release/compile_commands.json` and includes it in the filename:

- `generic` for `-march=x86-64 -mtune=generic`
- `native` for `-march=native`
- `unknown` if the build type cannot be detected

It also adds the architecture, packaging date and time, and the first eight characters of the current Ladybird Git commit.

For example:

```text
dist/Ladybird-x86_64-generic-20260915-2321-154e8d68.AppImage
```

The filename format is:

```text
Ladybird-{architecture}-{generic/native/unknown}-{YYYYMMDD-HHMM}-{git-hash}.AppImage
```

If Git metadata is unavailable, the hash field is written as `nogit`. Failure to detect the CPU build type or Git metadata does not stop AppImage creation.

A `native` AppImage may contain CPU instructions specific to the machine on which Ladybird was compiled and can therefore fail on older CPUs. Use `PORTABLE_BUILD=true` when creating an AppImage intended for wider distribution.

The AppImage packaging script bundles Ladybird's userspace dependencies, Qt plugins, helper processes, and the matching Cranelift compiler. It also applies several portability fixes intended to avoid dependencies on paths, libraries, runtime directories, and GPU driver files from the machine that created the package.

The AppImage is still experimental. It has not been tested on every Linux distribution, desktop environment, graphics stack, CPU generation, or hardware configuration.

A prebuilt example AppImage is available from the repository's [Releases](../../releases) page.

### AppImage compatibility testing

If the AppImage works on your system, feel free to open an issue or contact me with the generated compatibility row below. I would like to keep a simple list of systems on which the AppImage has been confirmed to work.

Run this one-liner after confirming that Ladybird starts and renders pages correctly:

```bash
. /etc/os-release 2>/dev/null; MODEL="$(printf '%s %s' "$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null)" "$(cat /sys/class/dmi/id/product_name 2>/dev/null)" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/|/\//g')"; GPU="$(command -v lspci >/dev/null 2>&1 && lspci 2>/dev/null | grep -Ei 'VGA|3D|Display' | head -n1 | sed -E 's/^[^ ]+ //' | sed 's/|/\//g' || printf unknown)"; printf '| %s | %s | %s | %s | %s | %s | %s | ✅ |\n' "$(date '+%Y-%m-%d')" "${PRETTY_NAME:-unknown}" "${MODEL:-unknown}" "$(uname -r)" "${XDG_CURRENT_DESKTOP:-unknown}" "${XDG_SESSION_TYPE:-unknown}" "${GPU:-unknown}"
```

It prints a ready-to-paste Markdown table row, for example:

```text
| 2026-09-17 | Debian GNU/Linux ... | LENOVO 82EY | 6.12... | XFCE | x11 | VGA compatible controller: NVIDIA ...| ✅ |
```

### Confirmed AppImage compatibility

| Date | Distribution | Computer model | Kernel | Desktop | Session | GPU | Result |
|---|---|---|---|---|---|---|---|
| YYYY-MM-DD | Distribution | Computer model | Kernel version | Desktop | x11/wayland | GPU | ✅ |
| 2026-09-17 | Debian GNU/Linux 13 (trixie) | LENOVO 82EY | 6.12.107+deb13-amd64 | XFCE | x11 | VGA compatible controller: NVIDIA Corporation TU117M [GeForce GTX 1650 Ti Mobile] (rev a1) | ✅ |
| 2026-09-17 | Pop!_OS 22.04 LTS | Acer Nitro AN515-57 | 7.1.1-76070101-generic | KDE | x11 | VGA compatible controller: Intel Corporation TigerLake-H GT1 [UHD Graphics] (rev 01) | ✅ |

## HTTPS / CA certificate troubleshooting

If the AppImage starts normally but websites do not load, check the terminal output. If you see an error similar to:

```text
Request::handle_complete_state: Unable to map error (77): "Problem with the SSL CA cert (path? access rights?)"
```

Ladybird may be unable to access your distribution's system CA certificate bundle from inside its sandbox.

Try launching the AppImage with an explicit CA bundle path.

### Debian / Ubuntu / Linux Mint / Pop!_OS

```bash
./Ladybird-*.AppImage --certificate /etc/ssl/certs/ca-certificates.crt
```

### Arch Linux / Artix / Manjaro

```bash
./Ladybird-*.AppImage --certificate /etc/ca-certificates/extracted/tls-ca-bundle.pem
```

### Fedora / RHEL / Rocky Linux / AlmaLinux

```bash
./Ladybird-*.AppImage --certificate /etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem
```

### openSUSE / SUSE Linux Enterprise

```bash
./Ladybird-*.AppImage --certificate /var/lib/ca-certificates/ca-bundle.pem
```

On some SUSE systems the same bundle is also exposed as `/etc/ssl/ca-bundle.pem`.

### Alpine Linux

```bash
./Ladybird-*.AppImage --certificate /etc/ssl/certs/ca-certificates.crt
```

If none of these paths exist on your system, you can check common CA bundle locations with:

```bash
for f in \
    /etc/ssl/certs/ca-certificates.crt \
    /etc/ca-certificates/extracted/tls-ca-bundle.pem \
    /etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem \
    /var/lib/ca-certificates/ca-bundle.pem \
    /etc/ssl/ca-bundle.pem \
    /etc/ssl/cert.pem
do
    [ -r "$f" ] && printf '%s -> %s\n' "$f" "$(readlink -f "$f")"
done
```

Then pass the resolved path to Ladybird with `--certificate`.

This is a workaround for CA bundle paths that Ladybird's current Linux sandbox may not be able to access automatically; it does not disable the sandbox.
