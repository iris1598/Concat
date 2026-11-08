#!/usr/bin/env bash
# The FFmpeg build for a phone, run from a Windows host - ffmpeg-mobile.sh
# asks for a Unix one, and its only Windows-side stumbling block is the
# host C compiler: a cross build still has one compiled as it starts
# (ffmpeg 8.1, configure: "Host compiler lacks C11 support"), and Git Bash
# ships no C compiler. Same vendor/ffmpeg/<target> output, the same
# configure args, with two differences:
#
# - the host compiler is a shim that aims the NDK's own clang.exe at the
#   machine's MSVC and Windows SDK, compile-only - the cross build runs no
#   host programs, so nothing on this side is ever linked;
# - `make` and the prefix go by Windows paths: ezwinports' make
#   (winget: ezwinports.make) is a Windows binary, and the paths it is
#   handed - the build tree, the prefix - are given mixed-form
#   (C:/...), which it and the recipes' MSYS shell both read.
#
#   scripts/ffmpeg-mobile-windows.sh aarch64-linux-android [out-dir]
#
# Run scripts/android-libs.sh and scripts/mobile-env.sh as on any other
# host once this is done; neither knows the difference.
set -euo pipefail

target=${1:?target triple: aarch64-linux-android or x86_64-linux-android}
workspace=$(cd "$(dirname "$0")/.." && pwd)
out=${2:-$workspace/vendor/ffmpeg/$target}
version=${FFMPEG_VERSION:-8.1}
android_api=${ANDROID_API:-26}
jobs=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)

ndk=${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-}}
if [ -z "$ndk" ]; then
  sdk_home=${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$LOCALAPPDATA/Android/Sdk}}
  ndk=$(ls -d "$sdk_home"/ndk/* 2>/dev/null | sort -V | tail -1 || true)
fi
[ -d "$ndk" ] || { echo "no Android NDK: set ANDROID_NDK_HOME" >&2; exit 1; }
host_tag=$(ls "$ndk/toolchains/llvm/prebuilt" | head -1)
bin=$ndk/toolchains/llvm/prebuilt/$host_tag/bin
echo "Building FFmpeg $version for $target with NDK at $ndk (API $android_api)"

# The machine's own MSVC and Windows SDK, the ground the host compiler
# stands on. Windows Kits' Include folder is the one place both versions
# are listed; the newest of each is taken.
msvc=$(ls -d "/c/Program Files (x86)/Microsoft Visual Studio/"*/*/VC/Tools/MSVC/* | sort -V | tail -1)
sdkinc=$(ls -d "/c/Program Files (x86)/Windows Kits/10/Include/"* | sort -V | tail -1)
[ -d "$msvc/include" ] || { echo "no MSVC under Program Files" >&2; exit 1; }
[ -f "$sdkinc/ucrt/stdio.h" ] || { echo "no Windows SDK ucrt under $sdkinc" >&2; exit 1; }

# The host compiler: the NDK's clang, told the target it is really for.
# Only ever compiled with - the C11 probe of configure, and nothing after
# it - so the SDK's headers are the whole of what it needs.
shim=$workspace/vendor/shim/host
mkdir -p "$shim"
cat > "$shim/cc" <<EOF
#!/bin/sh
exec "$bin/clang.exe" --target=x86_64-pc-windows-msvc \\
  -isystem "$(cygpath -m "$msvc")/include" \\
  -isystem "$(cygpath -m "$sdkinc")/ucrt" \\
  -isystem "$(cygpath -m "$sdkinc")/um" \\
  -isystem "$(cygpath -m "$sdkinc")/shared" \\
  "\$@"
EOF
chmod +x "$shim/cc"

work=${FFMPEG_WORK_DIR:-$workspace/vendor/ffmpeg/src}
src=$work/ffmpeg-$version
mkdir -p "$work"
if [ ! -f "$src/configure" ]; then
  echo "Fetching FFmpeg $version"
  curl -fsSL --retry 5 --retry-all-errors -o "$work/ffmpeg-$version.tar.xz" \
    "https://ffmpeg.org/releases/ffmpeg-$version.tar.xz"
  tar -xf "$work/ffmpeg-$version.tar.xz" -C "$work"
fi

# One build tree per target, so two phones can be built from one source.
build=$work/build-$target
rm -rf "$build"
mkdir -p "$build"

# Flags shared with ffmpeg-mobile.sh, kept the same on purpose: a phone
# build from either host is meant to be the same build. No programs, no
# docs, no shared libraries: the engine links the archives into one
# binary. Position independent because Android loads the app as a shared
# object. Nothing external; zlib is part of the platform's SDK.
common=(
  --prefix="$(cygpath -m "$out")"
  --enable-cross-compile
  --enable-static --disable-shared --enable-pic
  --disable-programs --disable-doc
  --disable-debug
  --enable-zlib --disable-bzlib --disable-lzma
  --disable-iconv --disable-sdl2 --disable-xlib --disable-libxcb
  --disable-vulkan --disable-opencl --disable-vaapi --disable-vdpau
)

if [ "$target" = aarch64-linux-android ]; then
  arch=(--arch=aarch64 --cpu=armv8-a)
else
  # The emulator's build, never shipped: no assembly, no assembler.
  arch=(--arch=x86_64 --disable-x86asm)
fi

(cd "$build" && "$src/configure" "${common[@]}" \
  --target-os=android "${arch[@]}" \
  --sysroot="$ndk/toolchains/llvm/prebuilt/$host_tag/sysroot" \
  --cc="$bin/$target$android_api-clang" \
  --cxx="$bin/$target$android_api-clang++" \
  --ar="$bin/llvm-ar" --nm="$bin/llvm-nm" --ranlib="$bin/llvm-ranlib" --strip="$bin/llvm-strip" \
  --host-cc="$shim/cc" \
  --enable-jni --enable-mediacodec \
  --extra-cflags="-fno-omit-frame-pointer" \
  --extra-ldflags="-Wl,-z,max-page-size=16384")

# configure writes the source tree's own path into the generated makefiles
# as bash sees it (/c/...), which the Windows make cannot open, and the
# paths the machine's environment contributed (ANDROID_HOME) arrive with
# the backslashes bash ate at their first sh crossing. Mixed form (C:/...)
# is what both make and the recipes' shell read.
sed -i 's|/c/|C:/|g' "$build/Makefile" "$build/ffbuild/config.mak"
sed -i 's|\\|/|g' "$build/ffbuild/config.mak"

# A static library's response file - every object of avformat in one
# `echo` - is a command line past Windows' 32 KiB, which sh receives
# truncated: the list prints, the redirect vanishes, llvm-ar finds no
# file. GNU make's own `file` function writes it without a shell in
# between. (Shared libraries are disabled; their rule keeps its echo.)
sed -i 's|echo \$\^ > \$@\.objs|$(file >$@.objs,$^)|' "$src/ffbuild/library.mak"

# The build tree by its Windows path, for the Windows make; the shell the
# recipes run under is Git Bash's own, so the two agree on what they read.
make -C "$(cygpath -m "$build")" -j"$jobs" install

# MSYS' install takes a C:/-form file destination and copies, but takes a
# C:/-form directory destination as no operation at all - the archives
# land, the headers silently do not. The headers go once more by their
# POSIX form, which the same install copies happily.
make -n -C "$(cygpath -m "$build")" install-headers 2>/dev/null | sed 's|C:/|/c/|g' | sh
echo "FFmpeg $version for $target is in $out"
echo "  export FFMPEG_DIR=$out"
