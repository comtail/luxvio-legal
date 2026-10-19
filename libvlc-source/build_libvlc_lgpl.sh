#!/usr/bin/env bash
#
# Reproducible LGPL build of LibVLC for Android (D-024, implementation plan phase 5c).
# Replaces org.videolan.android:libvlc-all (a GPL build) in LUXVIO.
#
# Runs on Linux x86_64 / WSL as a normal user (no root). Needs: bash, gcc/g++, make, cmake, perl,
# python3, git, curl, tar, xz, bzip2, patch. VLC's extras/tools bootstrap builds the remaining
# build tools (autotools, libtool, pkg-config, meson, ninja, nasm, …) into the work directory.
#
#   tools/libvlc/build_libvlc_lgpl.sh [abi ...]        (default: arm64-v8a armeabi-v7a x86 x86_64)
#
# License configuration (docs/LUXVIO_PLAYER_LICENSE_AUDIT.md, option B):
#   --license a      contribs LGPLv2.1 + advertising clauses: --disable-gpl --disable-gnuv3
#                    (drops x264/x265, libpostproc, libdvdcss/dvdread/dvdnav, a52, faad, libmpeg2, live555, gnutls …)
#   --disable-zvbi   zvbi compiles GPL-2-only files (packet-830.c, pdc.c)
#   --disable-lua    the Lua module is GPL-2+
#   --disable-sout   stream output (rtp/cycle modules are GPL-2+), not needed for playback
#   blacklist        further GPL-2+ modules: rotate, dolby surround / headphone / mono channel mixers, realrtsp,
#                    dummy (control), file_logger, syslog (reported by the license gate in the first build)
#   AVLC_STATIC_CXX  C++ runtime linked statically (no libc++_shared.so clash with other libraries)
# Every result is scanned with tools/inspect_native_libs.py; the script fails on any GPL marker.
set -euo pipefail

LIBVLCJNI_HASH="0b8dc65efb203c86a0476bc337ddd99ecf1c0ef6" # libvlcjni-3.x, pinned by vlc-android tag libvlc-3.7.7
# libvlcjni 3.x: NDK r27-r29 for 64-bit ABIs, NDK r21 for 32-bit ABIs (API 17 support), like VideoLAN's own CI.
NDK64_VERSION="r27c"
NDK64_ZIP="android-ndk-r27c-linux.zip"
NDK64_SHA256="59c2f6dc96743b5daf5d1626684640b20a6bd2b1d85b13156b90333741bad5cc"
NDK32_VERSION="r21e"
NDK32_ZIP="android-ndk-r21e-linux-x86_64.zip"
NDK32_SHA256="ad7ce5467e18d40050dc51b8e7affc3e635c85bd8c59be62de32352328ed467e"
ABIS=("$@")
[[ ${#ABIS[@]} -gt 0 ]] || ABIS=(arm64-v8a armeabi-v7a x86 x86_64)

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="${LUXVIO_VLC_WORK:-$HOME/luxvio-vlc-build}"
OUT="$REPO/third_party/libvlc-lgpl"
mkdir -p "$WORK/bin" "$OUT"
cd "$WORK"
export PATH="$WORK/bin:$PATH"
# get-vlc.sh applies VideoLAN's patches with `git am`, which needs an identity (local to this build only).
export GIT_AUTHOR_NAME="LUXVIO build" GIT_AUTHOR_EMAIL="build@luxvio.invalid"
export GIT_COMMITTER_NAME="LUXVIO build" GIT_COMMITTER_EMAIL="build@luxvio.invalid"

# unzip is not always installed; a few contribs need it.
if ! command -v unzip >/dev/null; then
    cat > "$WORK/bin/unzip" <<'PY'
#!/usr/bin/env python3
import os, stat, sys, zipfile
args = [a for a in sys.argv[1:] if not a.startswith('-')]
dest = '.'
if '-d' in sys.argv:
    dest = sys.argv[sys.argv.index('-d') + 1]
    args.remove(dest)
with zipfile.ZipFile(args[0]) as z:
    for info in z.infolist():
        attr = info.external_attr >> 16
        path = z.extract(info, dest)
        if attr & 0o777:
            os.chmod(path, attr & 0o777)
PY
    chmod +x "$WORK/bin/unzip"
fi

# --- Android NDK -------------------------------------------------------------------------------
fetch_ndk() { # version zip sha256 -> prints the NDK directory
    local version="$1" zip="$WORK/$2" sum="$3"
    [[ -f "$zip" ]] || curl -fL --retry 3 -o "$zip" "https://dl.google.com/android/repository/$2" >&2
    echo "$sum  $zip" | sha256sum -c - >&2
    if [[ ! -d "$WORK/android-ndk-$version" ]]; then
        (cd "$WORK" && python3 - "$zip" <<'PY'
import os, stat, sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as z:
    for info in z.infolist():
        attr = info.external_attr >> 16
        if stat.S_ISLNK(attr):
            os.makedirs(os.path.dirname(info.filename), exist_ok=True)
            os.symlink(z.read(info).decode(), info.filename)
            continue
        path = z.extract(info)
        if attr & 0o777:
            os.chmod(path, attr & 0o777)
PY
        )
    fi
    echo "$WORK/android-ndk-$version"
}
ndk_for() { # abi -> NDK directory
    case "$1" in
        armeabi-v7a|x86) fetch_ndk "$NDK32_VERSION" "$NDK32_ZIP" "$NDK32_SHA256" ;;
        *) fetch_ndk "$NDK64_VERSION" "$NDK64_ZIP" "$NDK64_SHA256" ;;
    esac
}

# --- Sources -----------------------------------------------------------------------------------
[[ -d libvlcjni ]] || git clone -q -b libvlcjni-3.x https://code.videolan.org/videolan/libvlcjni.git
cd libvlcjni
git reset -q --hard "$LIBVLCJNI_HASH"
git clean -qfd buildsystem
# A clone without VideoLAN's patches (interrupted earlier run) is discarded and fetched again.
if [[ -d vlc && ! -f vlc/.luxvio-patched ]]; then rm -rf vlc; fi
if [[ ! -d vlc ]]; then
    buildsystem/get-vlc.sh
    touch vlc/.luxvio-patched
fi
VLC_HASH="$(git -C vlc rev-parse HEAD)"

# VLC's extras/tools Makefile lets flex/bison configure in parallel with m4, which they need (race with
# many jobs on hosts without m4). Build m4 first; compile-libvlc.sh then builds the remaining tools.
TOOLS="$PWD/vlc/extras/tools"
export PATH="$TOOLS/build/bin:$PATH"
if ! command -v m4 >/dev/null; then
    (cd "$TOOLS" && ./bootstrap && make .buildm4)
fi
# autopoint (gettext) is needed by libgpg-error's autoreconf; VLC's tools can build gettext.
if ! command -v autopoint >/dev/null; then
    (cd "$TOOLS" && make .buildgettext)
fi
# gperf is needed by fontconfig and not covered by VLC's tools.
if ! command -v gperf >/dev/null; then
    GPERF=gperf-3.1
    [[ -f "$WORK/$GPERF.tar.gz" ]] || curl -fL --retry 3 -o "$WORK/$GPERF.tar.gz" "https://ftp.gnu.org/gnu/gperf/$GPERF.tar.gz"
    echo "588546b945bba4b70b6a3a616e80b4ab466e3f33024a352fc2198112cdbb3ae2  $WORK/$GPERF.tar.gz" | sha256sum -c -
    rm -rf "$WORK/$GPERF" && tar xf "$WORK/$GPERF.tar.gz" -C "$WORK"
    (cd "$WORK/$GPERF" && ./configure -q --prefix="$TOOLS/build" && make -s -j"$(nproc)" && make -s install)
fi

# --- LGPL configuration (applied to the pinned upstream script, see header) ---------------------
S=buildsystem/compile-libvlc.sh
sed -i 's/--enable-zvbi/--disable-zvbi/g; s/--enable-lua/--disable-lua/g; s/--enable-sout/--disable-sout/g; s/--enable-realrtsp/--disable-realrtsp/g' "$S"
grep -q 'LUXVIO GPL modules' "$S" || sed -i 's/^VLC_MODULE_BLACKLIST="$/VLC_MODULE_BLACKLIST="\n    rotate\n    dolby_surround_decoder\n    headphone_channel_mixer\n    mono\n    access_realrtsp\n    lua\n    stream_out_.*\n    dummy\n    file_logger\n    syslog\n    # LUXVIO GPL modules (GPL-2+ module sources, see tools\/libvlc\/build_libvlc_lgpl.sh)/' "$S"
# Comment lines inside the blacklist would end up in the regexp; remove the marker again after insertion.
sed -i '/# LUXVIO GPL modules/d' "$S"
# Static C++ runtime with NDK r21 (32-bit ABIs): clang 9 lacks --start/--end-no-unused-arguments (use
# -Qunused-arguments), and r21's ndk-build puts libc++_static.a before the VLC archives on the libvlc.so link line,
# so the runtime archives are appended once more at the end of that link.
python3 - "$S" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
if 'LUXVIO r21' not in s:
    old = '    VLC_CXXFLAGS="$VLC_CXXFLAGS -static --start-no-unused-arguments -static-libstdc++ --end-no-unused-arguments"\n'
    new = ('    if [ "$REL" = 21 ]; then # LUXVIO r21\n'
           '        VLC_CXXFLAGS="$VLC_CXXFLAGS -static -Qunused-arguments -static-libstdc++"\n'
           '        STL_DIR="$ANDROID_NDK/sources/cxx-stl/llvm-libc++/libs/$ANDROID_ABI"\n'
           '        LUXVIO_R21_STL="$STL_DIR/libc++_static.a $STL_DIR/libc++abi.a $STL_DIR/libandroid_support.a"\n'
           '        [ -f "$STL_DIR/libunwind.a" ] && LUXVIO_R21_STL="$LUXVIO_R21_STL $STL_DIR/libunwind.a"\n'
           '    else\n' + old + '    fi\n')
    link_old = '    VLC_LDFLAGS="$VLC_LDFLAGS" \\\n    VLC_BUILD_JNI'
    link_new = '    VLC_LDFLAGS="$VLC_LDFLAGS $LUXVIO_R21_STL" \\\n    VLC_BUILD_JNI'
    assert s.count(old) == 1 and s.count(link_old) == 1, "r21 patch anchors not found"
    s = s.replace(old, new).replace(link_old, link_new)
    open(p, 'w').write(s)
PY
grep -q 'LUXVIO_LGPL_PATCHED' "$S" || echo "# LUXVIO_LGPL_PATCHED" >> "$S"

for ABI in "${ABIS[@]}"; do
    echo "=== building $ABI"
    ANDROID_NDK="$(ndk_for "$ABI")"
    if ! AVLC_STATIC_CXX=1 ANDROID_NDK="$ANDROID_NDK" "$S" -a "$ABI" --release --license a > "$WORK/build-$ABI.log" 2>&1; then
        grep -E 'Error [0-9]|error:' "$WORK/build-$ABI.log" | tail -15 >&2
        echo "build failed for $ABI, see $WORK/build-$ABI.log" >&2
        exit 1
    fi
    mkdir -p "$OUT/jniLibs/$ABI"
    rm -f "$OUT/jniLibs/$ABI"/*.so
    find libvlc -path "*/$ABI/*" \( -name libvlc.so -o -name libvlcjni.so \) -newer "$S" -exec cp {} "$OUT/jniLibs/$ABI/" \;
    for lib in libvlc.so libvlcjni.so; do
        [[ -s "$OUT/jniLibs/$ABI/$lib" ]] || { echo "missing $lib for $ABI" >&2; exit 1; }
    done
    ls -la "$OUT/jniLibs/$ABI"
done

# --- License gate on the result (shared heuristic + reviewed allowlist, see tools/inspect_native_libs.py) ----
python3 -I "$REPO/tools/inspect_native_libs.py" "$OUT/jniLibs" all

{
    echo "LibVLC for LUXVIO, LGPL build"
    echo "Built: $(date -u +%Y-%m-%dT%H:%M:%SZ) on $(uname -srm)"
    echo "libvlcjni $LIBVLCJNI_HASH (branch libvlcjni-3.x), vlc $VLC_HASH"
    echo "Android NDK $NDK64_VERSION sha256 $NDK64_SHA256 (64-bit), $NDK32_VERSION sha256 $NDK32_SHA256 (32-bit)"
    echo "compile-libvlc.sh --license a + --disable-zvbi --disable-lua --disable-sout --disable-realrtsp, GPL modules blacklisted, AVLC_STATIC_CXX=1"
    echo "ABIs: $(ls "$OUT/jniLibs" | xargs) (this run: ${ABIS[*]})"
    echo "Rebuild: tools/libvlc/build_libvlc_lgpl.sh"
} > "$OUT/BUILDINFO.txt"
git diff > "$OUT/compile-libvlc.lgpl.patch"
echo "done -> $OUT"
