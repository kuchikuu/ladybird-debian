#!/usr/bin/env bash
set -euo pipefail

# Build a portable Ladybird AppImage from an already-built Ladybird tree.
# Run from the Ladybird repository root.
#
# This version incorporates the fixes discovered while debugging the v2 AppImage:
# - bundle the matching cranelift-compiler from the local build
# - route Ladybird helper processes through sharun entrypoints
# - relocate vcpkg libraries away from build-machine absolute paths
# - remove build-machine RPATH/RUNPATH entries
# - create a safe per-user XDG_RUNTIME_DIR fallback
# - shim time() through clock_gettime() for Ladybird seccomp compatibility
# - avoid shipping build-host NVIDIA driver payloads
# - undo quick-sharun's fixed /tmp mapping for /usr/share when possible
# - fix desktop icon metadata and known broken symlinks

ROOT="${ROOT:-$PWD}"
BUILD="${BUILD:-$ROOT/Build/release}"
VCPKG="${VCPKG:-$BUILD/vcpkg_installed/x64-linux-dynamic}"
VCPKG_LIB="$VCPKG/lib"
WORK="${WORK:-$ROOT/AppImageBuild}"
APPDIR="${APPDIR:-$WORK/AppDir}"
DIST="${DIST:-$ROOT/dist}"
ARCH="${ARCH:-$(uname -m)}"
OUTNAME="${OUTNAME:-Ladybird-${ARCH}.AppImage}"
CRANELIFT="${CRANELIFT:-$BUILD/bin/cranelift-compiler}"
QUICK_SHARUN_URL="${QUICK_SHARUN_URL:-https://raw.githubusercontent.com/pkgforge-dev/Anylinux-AppImages/refs/heads/main/useful-tools/quick-sharun.sh}"
QUICK_SHARUN="$WORK/quick-sharun"
SMOKE_TEST="${SMOKE_TEST:-0}"

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

note() {
    printf '==> %s\n' "$*"
}

# Report all missing tools at once.
required_tools=(
    awk cc curl file find grep id ldd patchelf python3 readelf readlink
    sed sha256sum stat strings tar tr xvfb-run dbus-launch
)
missing=()
for tool in "${required_tools[@]}"; do
    command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
done

if ((${#missing[@]})); then
    printf 'ERROR: Missing required programs: %s\n' "${missing[*]}" >&2
    printf 'On Debian 13, install:\n' >&2
    printf '  sudo apt install build-essential patchelf binutils coreutils findutils grep tar gawk sed curl xvfb dbus-x11 file python3\n' >&2
    exit 1
fi

if [[ "$SMOKE_TEST" == "1" ]] && ! command -v timeout >/dev/null 2>&1; then
    fail "SMOKE_TEST=1 requires the 'timeout' program (coreutils package)"
fi

[[ -x "$BUILD/bin/Ladybird" ]] || fail "Could not find $BUILD/bin/Ladybird"
[[ -x "$CRANELIFT" ]] || fail "Could not find cranelift-compiler: $CRANELIFT"
[[ -d "$BUILD/lib" ]] || fail "Could not find $BUILD/lib"
[[ -d "$BUILD/libexec" ]] || fail "Could not find $BUILD/libexec"
[[ -d "$BUILD/share/Lagom" ]] || fail "Could not find $BUILD/share/Lagom"
[[ -d "$VCPKG_LIB" ]] || fail "Could not find $VCPKG_LIB"
[[ -d "$VCPKG/Qt6/plugins" ]] || fail "Could not find $VCPKG/Qt6/plugins"
[[ -f "$ROOT/Meta/CMake/freedesktop/org.ladybird.Ladybird.desktop" ]] || fail "Missing .desktop file in the repository"
[[ -f "$ROOT/Base/res/icons/128x128/app-browser.png" ]] || fail "Missing Ladybird icon"

note "Cleaning old AppDir"
rm -rf "$WORK"
mkdir -p "$APPDIR/bin" "$APPDIR/lib" "$APPDIR/libexec" "$APPDIR/share" "$DIST"

# Do not use cmake --install here. A partial Ladybird build may contain install
# rules for configured-but-unbuilt targets, even while Ladybird itself is usable.
note "Copying the existing Ladybird build"
cp -a "$BUILD/bin/Ladybird" "$APPDIR/bin/"
cp -a "$CRANELIFT" "$APPDIR/bin/cranelift-compiler"
cp -a "$BUILD/libexec/." "$APPDIR/libexec/"
cp -a "$BUILD/lib/." "$APPDIR/lib/"
cp -a "$BUILD/share/Lagom" "$APPDIR/share/"

# Qt plugins are dlopen()'d and are not fully discoverable from ldd alone.
note "Copying Qt plugins"
mkdir -p "$APPDIR/lib/qt6"
cp -a "$VCPKG/Qt6/plugins" "$APPDIR/lib/qt6/"

cat > "$APPDIR/bin/qt.conf" <<'QTEOF'
[Paths]
Plugins=../lib/qt6/plugins
QTEOF

# Use a copy of the desktop file so the repository is never modified.
DESKTOP_FIXED="$WORK/org.ladybird.Ladybird.desktop"
ICON_FIXED="$WORK/app-browser.png"
cp -a "$ROOT/Meta/CMake/freedesktop/org.ladybird.Ladybird.desktop" "$DESKTOP_FIXED"
cp -a "$ROOT/Base/res/icons/128x128/app-browser.png" "$ICON_FIXED"
sed -i 's/^Icon=.*/Icon=app-browser/' "$DESKTOP_FIXED"

note "Downloading quick-sharun"
curl -L --fail --retry 3 "$QUICK_SHARUN_URL" -o "$QUICK_SHARUN"
chmod +x "$QUICK_SHARUN"

export APPDIR ARCH
export OUTPATH="$DIST"
export OUTNAME
export MAIN_BIN=Ladybird
export ICON="$ICON_FIXED"
export DESKTOP="$DESKTOP_FIXED"
export ANYLINUX_LIB=1

# Keep symbols by default. Set STRIP=1 to reduce size.
if [[ "${STRIP:-0}" == "1" ]]; then
    export STRIP=1
    unset NO_STRIP || true
else
    export NO_STRIP=1
fi

# Feed quick-sharun Ladybird, every helper, Ladybird's own libraries and Qt
# plugins. The vcpkg search path is supplied while dependencies are collected.
deploy=("$APPDIR/bin/Ladybird" "$APPDIR/bin/cranelift-compiler")

while IFS= read -r -d '' f; do
    deploy+=("$f")
done < <(find "$APPDIR/libexec" -maxdepth 1 -type f -perm /111 -print0)

while IFS= read -r -d '' f; do
    deploy+=("$f")
done < <(find "$APPDIR/lib" -maxdepth 1 \( -type f -o -type l \) -name '*.so*' -print0)

while IFS= read -r -d '' f; do
    deploy+=("$f")
done < <(find "$APPDIR/lib/qt6/plugins" -type f -name '*.so*' -print0)

# ANGLE is loaded dynamically and can escape ldd discovery.
for angle_lib in "$VCPKG_LIB/liblibEGL_angle.so" "$VCPKG_LIB/liblibGLESv2_angle.so"; do
    [[ -e "$angle_lib" ]] && deploy+=("$angle_lib")
done

note "Analyzing dependencies (${#deploy[@]} input files)"
LD_LIBRARY_PATH="$APPDIR/lib:$BUILD/lib:$VCPKG_LIB${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
    "$QUICK_SHARUN" "${deploy[@]}"

# ---------------------------------------------------------------------------
# Post-deployment fixes
# ---------------------------------------------------------------------------

# quick-sharun moves ELF payloads into shared/bin and creates bin/<name>
# entrypoints through sharun. Ladybird launches helpers from libexec/<name>, so
# leaving the original ELF there bypasses sharun and keeps build-machine paths.
note "Routing libexec helpers through sharun"
helpers=(RequestServer WebContent WebWorker Compositor WasmCompiler ImageDecoder)
for name in "${helpers[@]}"; do
    if [[ -e "$APPDIR/bin/$name" || -L "$APPDIR/bin/$name" ]]; then
        rm -f "$APPDIR/libexec/$name"
        ln -s "../bin/$name" "$APPDIR/libexec/$name"
        printf '    libexec/%s -> ../bin/%s\n' "$name" "$name"
    elif [[ -e "$APPDIR/libexec/$name" ]]; then
        fail "quick-sharun did not create bin/$name; refusing to leave the raw helper in libexec"
    fi
done

# Expose cranelift through the same sharun entrypoint scheme.
[[ -e "$APPDIR/bin/cranelift-compiler" || -L "$APPDIR/bin/cranelift-compiler" ]] \
    || fail "quick-sharun lost bin/cranelift-compiler"
[[ -x "$APPDIR/shared/bin/cranelift-compiler" ]] \
    || fail "quick-sharun did not create shared/bin/cranelift-compiler"
ln -sfn ../bin/cranelift-compiler "$APPDIR/libexec/cranelift-compiler"

# quick-sharun may preserve an absolute vcpkg source tree under AppDir/lib.
# Move that payload into a normal relative vendor directory and teach lib.path
# to use it.
note "Relocating vcpkg dependencies to lib/vendor"
NESTED_VCPKG="$APPDIR/lib$VCPKG_LIB"
if [[ -d "$NESTED_VCPKG" ]]; then
    mkdir -p "$APPDIR/lib/vendor"
    cp -a "$NESTED_VCPKG/." "$APPDIR/lib/vendor/"
fi

if [[ -f "$APPDIR/lib/lib.path" ]]; then
    python3 - "$APPDIR/lib/lib.path" "$VCPKG_LIB" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
vcpkg = sys.argv[2]
lines = p.read_text(errors="surrogateescape").splitlines()
out = []
seen_vendor = False
for line in lines:
    if line == "+" + vcpkg or line == vcpkg:
        line = "+/vendor"
    elif vcpkg in line:
        line = line.replace(vcpkg, "/vendor")
    if line == "+/vendor":
        seen_vendor = True
    out.append(line)
if not seen_vendor:
    out.append("+/vendor")
p.write_text("\n".join(out) + "\n")
PY
fi

# Remove nested copies of this build machine's absolute filesystem tree after
# the vcpkg payload has been relocated. Limit automatic top-level removal to
# ordinary developer locations.
case "$ROOT" in
    /home/*|/tmp/*|/mnt/*)
        root_rel="${ROOT#/}"
        local_top="${root_rel%%/*}"
        [[ -n "$local_top" ]] && rm -rf "$APPDIR/lib/$local_top"
        ;;
    *)
        rm -rf "$NESTED_VCPKG"
        ;;
esac

# Remove any RPATH/RUNPATH that still points at a developer/build directory.
note "Removing build-machine absolute RPATH/RUNPATH entries"
while IFS= read -r -d '' elf; do
    file -b "$elf" 2>/dev/null | grep -q '^ELF ' || continue
    dyn="$(readelf -d "$elf" 2>/dev/null || true)"
    rpath="$(grep -E '\((RPATH|RUNPATH)\)' <<<"$dyn" || true)"
    [[ -n "$rpath" ]] || continue
    if grep -Fq "$ROOT" <<<"$rpath" \
        || grep -Fq "$BUILD" <<<"$rpath" \
        || grep -Fq "$VCPKG" <<<"$rpath" \
        || grep -Eq '/home/[^/]+/' <<<"$rpath"; then
        printf '    remove: %s\n' "$elf"
        patchelf --remove-rpath "$elf"
    fi
done < <(find "$APPDIR" -type f -print0)

# quick-sharun patches hardcoded /usr/share into a fixed-length /tmp token.
# That token can collide between different users of the same AppImage. For the
# /usr/share mapping, restore the original 10-byte string and disable only the
# corresponding _tmp_share symlink hook. This also lets GPU/GLVND metadata come
# from the host rather than the build machine.
PATHMAP_HOOK="$APPDIR/bin/01-path-mapping-hardcoded.hook"
if [[ -f "$PATHMAP_HOOK" ]]; then
    tmp_share="$(sed -n 's/^_tmp_share=//p' "$PATHMAP_HOOK" | head -n1)"
    if [[ -n "$tmp_share" ]]; then
        old="/tmp/$tmp_share"
        if [[ ${#old} -eq 10 ]]; then
            note "Restoring /usr/share instead of fixed mapping $old"
            python3 - "$APPDIR" "$PATHMAP_HOOK" "$old" <<'PY'
from pathlib import Path
import os, sys
root = Path(sys.argv[1])
hook = Path(sys.argv[2]).resolve()
old = sys.argv[3].encode()
new = b"/usr/share"
assert len(old) == len(new)
count = 0
for p in root.rglob("*"):
    try:
        if not p.is_file() or p.is_symlink() or p.resolve() == hook:
            continue
        data = p.read_bytes()
    except (OSError, PermissionError):
        continue
    n = data.count(old)
    if n:
        p.write_bytes(data.replace(old, new))
        count += n
print(f"    restored {count} occurrence(s)")
PY
            sed -i 's/^_tmp_share=.*/_tmp_share=/' "$PATHMAP_HOOK"
        else
            printf 'WARNING: unexpected _tmp_share=%s; leaving the hook unchanged\n' "$tmp_share" >&2
        fi
    fi
fi

# Do not ship build-host NVIDIA driver implementation files. The host must
# provide the actual GPU driver stack. Keep generic loader libraries intact.
note "Removing NVIDIA drivers copied from the build host"
shopt -s nullglob
nvidia_files=(
    "$APPDIR"/lib/libnvidia*.so*
    "$APPDIR"/lib/libGLX_nvidia.so*
    "$APPDIR"/lib/libEGL_nvidia.so*
    "$APPDIR"/lib/vdpau/libvdpau_nvidia.so*
    "$APPDIR"/lib/gbm/nvidia*.so*
    "$APPDIR"/lib/nvidia/current/libnvidia*.so*
    "$APPDIR"/lib/nvidia/current/libGLX_nvidia.so*
    "$APPDIR"/lib/nvidia/current/libEGL_nvidia.so*
    "$APPDIR"/lib/nvidia/current/libvdpau_nvidia.so*
    "$APPDIR"/share/vulkan/icd.d/*nvidia*.json
    "$APPDIR"/share/glvnd/egl_vendor.d/*nvidia*.json
)
for f in "${nvidia_files[@]}"; do
    [[ -e "$f" || -L "$f" ]] || continue
    printf '    remove: %s\n' "${f#$APPDIR/}"
    rm -f "$f"
done
shopt -u nullglob

# Remove the two broken symlinks observed in the faulty package, but only when
# they are actually dangling.
for f in "$APPDIR/lib/libGLX_indirect.so.0" "$APPDIR/share/icons/hicolor/scalable/apps/wine.svg"; do
    if [[ -L "$f" && ! -e "$f" ]]; then
        printf '    remove broken symlink: %s\n' "${f#$APPDIR/}"
        rm -f "$f"
    fi
done

# Ensure the final desktop metadata matches the packaged icon name.
if [[ -f "$APPDIR/org.ladybird.Ladybird.desktop" ]]; then
    sed -i 's/^Icon=.*/Icon=app-browser/' "$APPDIR/org.ladybird.Ladybird.desktop"
fi

# A normal graphical login provides XDG_RUNTIME_DIR. For unusual sessions (su,
# test users, minimal environments), create a private per-UID fallback instead
# of trying to mkdir /run/user/<uid>.
note "Adding a safe XDG_RUNTIME_DIR fallback"
cat > "$APPDIR/bin/00-runtime.hook" <<'HOOK'
#!/bin/sh
_runtime_uid=$(id -u)
_valid_runtime() {
    [ -n "$1" ] && [ -d "$1" ] && [ ! -L "$1" ] \
        && [ "$(stat -c '%u:%a' -- "$1" 2>/dev/null)" = "$_runtime_uid:700" ] \
        && [ -w "$1" ] && [ -x "$1" ]
}
if ! _valid_runtime "${XDG_RUNTIME_DIR:-}"; then
    _runtime_dir=/tmp/ladybird-runtime-$_runtime_uid
    (umask 077; mkdir -m 700 -- "$_runtime_dir") 2>/dev/null || :
    _valid_runtime "$_runtime_dir" || _runtime_dir=$(mktemp -d /tmp/ladybird-runtime-$_runtime_uid.XXXXXXXX)
    export XDG_RUNTIME_DIR=$_runtime_dir
fi
# vcpkg dbus builds can embed a build-machine system-bus socket path. The
# environment override is safer and does not require patching libdbus bytes.
export DBUS_SYSTEM_BUS_ADDRESS="${DBUS_SYSTEM_BUS_ADDRESS:-unix:path=/run/dbus/system_bus_socket}"
unset _runtime_uid _runtime_dir
HOOK
chmod 755 "$APPDIR/bin/00-runtime.hook"

# sharun's cross-libc setup can make glibc time() issue syscall 201 directly.
# Ladybird's Compositor/WasmCompiler seccomp policy rejects that syscall, while
# clock_gettime(CLOCK_REALTIME) is allowed. Preload a tiny ABI-compatible shim.
note "Adding time() -> clock_gettime() shim for the Ladybird sandbox"
mkdir -p "$APPDIR/lib/sharun-preload"
TIME_C="$WORK/ladybird-time.c"
cat > "$TIME_C" <<'C'
#include <time.h>
time_t time(time_t *result)
{
    struct timespec ts;
    if (clock_gettime(CLOCK_REALTIME, &ts) != 0)
        return (time_t)-1;
    if (result)
        *result = ts.tv_sec;
    return ts.tv_sec;
}
C
cc -shared -fPIC -O2 -Wl,-z,relro,-z,now "$TIME_C" -o "$APPDIR/lib/sharun-preload/ladybird-time.so"

cat > "$APPDIR/bin/02-compiler.hook" <<'HOOK'
#!/bin/sh
export LD_LIBRARY_PATH="$APPDIR${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export LD_PRELOAD="$APPDIR/lib/sharun-preload/ladybird-time.so${LD_PRELOAD:+:$LD_PRELOAD}"
if [ -z "${LADYBIRD_CRANELIFT_COMPILER:-}" ]; then
    export LADYBIRD_CRANELIFT_COMPILER="$APPDIR/bin/cranelift-compiler"
fi
HOOK
chmod 755 "$APPDIR/bin/02-compiler.hook"

# ---------------------------------------------------------------------------
# Validation before packing
# ---------------------------------------------------------------------------

note "Validating helpers and Cranelift"
for helper in "${helpers[@]}"; do
    [[ -L "$APPDIR/libexec/$helper" ]] || fail "libexec/$helper is not a symlink to sharun"
    [[ "$(readlink "$APPDIR/libexec/$helper")" == "../bin/$helper" ]] \
        || fail "libexec/$helper points to $(readlink "$APPDIR/libexec/$helper")"
done
[[ -e "$APPDIR/bin/cranelift-compiler" || -L "$APPDIR/bin/cranelift-compiler" ]] \
    || fail "Missing bin/cranelift-compiler"
[[ -L "$APPDIR/libexec/cranelift-compiler" ]] \
    || fail "Missing libexec/cranelift-compiler -> ../bin/cranelift-compiler"

note "Validating RPATH/RUNPATH"
bad_rpath=0
elf_count=0
while IFS= read -r -d '' elf; do
    file -b "$elf" 2>/dev/null | grep -q '^ELF ' || continue
    ((elf_count+=1))
    dyn="$(readelf -d "$elf" 2>/dev/null || true)"
    rpath="$(grep -E '\((RPATH|RUNPATH)\)' <<<"$dyn" || true)"
    [[ -n "$rpath" ]] || continue
    if grep -Fq "$ROOT" <<<"$rpath" \
        || grep -Fq "$BUILD" <<<"$rpath" \
        || grep -Fq "$VCPKG" <<<"$rpath" \
        || grep -Eq '/home/[^/]+/' <<<"$rpath"; then
        printf 'ERROR: local RPATH/RUNPATH remains in %s\n%s\n' "$elf" "$rpath" >&2
        bad_rpath=1
    fi
done < <(find "$APPDIR" -type f -print0)
(( bad_rpath == 0 )) || fail "AppDir still contains loader paths from the build machine"
printf '    ELF files checked: %d\n' "$elf_count"

# Ensure the old absolute vcpkg tree is no longer present in AppDir.
if [[ -d "$APPDIR/lib$VCPKG_LIB" ]]; then
    fail "Nested vcpkg tree still remains: $APPDIR/lib$VCPKG_LIB"
fi

# The exact build path may legitimately remain in debug/source strings. We only
# reject it in loader configuration and lib.path, which affect runtime loading.
if [[ -f "$APPDIR/lib/lib.path" ]] && grep -Fq "$ROOT" "$APPDIR/lib/lib.path"; then
    fail "lib.path still contains $ROOT"
fi

note "Creating AppImage"
"$QUICK_SHARUN" --make-appimage

printf '\n==> Contents of the dist directory:\n'
ls -lh "$DIST"

if [[ -f "$DIST/$OUTNAME" ]]; then
    printf '\nDONE: %s\n' "$DIST/$OUTNAME"
    printf 'Size: '
    du -h "$DIST/$OUTNAME" | awk '{print $1}'

    if [[ "$SMOKE_TEST" == "1" ]]; then
        note "Smoke test AppImage (12 s, Xvfb, CPU painting)"
        set +e
        timeout 12s xvfb-run -a -- "$DIST/$OUTNAME" --temporary-profile --force-cpu-painting >/tmp/ladybird-appimage-smoke.log 2>&1
        status=$?
        set -e
        # timeout=124 means the browser stayed alive for the whole test window.
        if [[ $status -ne 0 && $status -ne 124 ]]; then
            cat /tmp/ladybird-appimage-smoke.log >&2 || true
            fail "Smoke test exited with status $status"
        fi
        printf '    smoke test: OK\n'
    fi

    printf '\nRun with:\n  chmod +x %q\n  %q\n' "$DIST/$OUTNAME" "$DIST/$OUTNAME"
else
    printf '\nThe AppImage was created, but quick-sharun may have given it a different name.\n'
fi
