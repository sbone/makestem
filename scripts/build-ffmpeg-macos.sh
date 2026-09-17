#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
build_root="$repo_root/build/dependencies"
source_root="$build_root/src"
prefix="$build_root/prefix"
bin_dir="$build_root/bin"
ffmpeg_version="8.0.1"
lame_version="3.100"
deployment_target="14.0"
target_stamp="$build_root/.deployment-target"
build_jobs="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"

export MACOSX_DEPLOYMENT_TARGET="$deployment_target"

mkdir -p "$source_root" "$prefix" "$bin_dir"

download() {
  local url="$1"
  local destination="$2"
  if [[ ! -f "$destination" ]]; then
    curl --fail --location --progress-bar "$url" --output "$destination"
  fi
}

download \
  "https://downloads.sourceforge.net/project/lame/lame/$lame_version/lame-$lame_version.tar.gz" \
  "$source_root/lame-$lame_version.tar.gz"
download \
  "https://ffmpeg.org/releases/ffmpeg-$ffmpeg_version.tar.xz" \
  "$source_root/ffmpeg-$ffmpeg_version.tar.xz"
download \
  "https://raw.githubusercontent.com/nikhilunni/demucs-rs/main/LICENSE" \
  "$source_root/demucs-rs-Apache-2.0.txt"

if [[ ! -d "$source_root/lame-$lame_version" ]]; then
  tar -xzf "$source_root/lame-$lame_version.tar.gz" -C "$source_root"
fi
if [[ ! -d "$source_root/ffmpeg-$ffmpeg_version" ]]; then
  tar -xJf "$source_root/ffmpeg-$ffmpeg_version.tar.xz" -C "$source_root"
fi

finish_build() {
  for executable in "$bin_dir/ffmpeg" "$bin_dir/ffprobe"; do
    if otool -L "$executable" | tail -n +2 | grep -E '/opt/homebrew|/usr/local|/build/dependencies'; then
      echo "Unexpected non-system dynamic dependency in $executable" >&2
      exit 1
    fi
  done

  mkdir -p "$build_root/licenses"
  cp "$source_root/ffmpeg-$ffmpeg_version/COPYING.LGPLv2.1" "$build_root/licenses/FFmpeg-LGPL-2.1.txt"
  cp "$source_root/lame-$lame_version/COPYING" "$build_root/licenses/LAME-LGPL-2.0.txt"
  cp "$source_root/demucs-rs-Apache-2.0.txt" "$build_root/licenses/demucs-rs-Apache-2.0.txt"
  rm -f "$build_root/licenses/Demucs-model-MIT.txt"
  echo "$deployment_target" > "$target_stamp"
  echo "Built self-contained FFmpeg tools in $bin_dir"
}

deployment_is_compatible() {
  local executable="$1"
  local minos
  minos="$(vtool -show-build "$executable" 2>/dev/null | awk '/minos/ { print $2; exit }')"
  [[ -n "$minos" ]] && awk -v actual="$minos" -v maximum="$deployment_target" 'BEGIN {
    split(actual, a, "."); split(maximum, m, ".")
    exit !((a[1] < m[1]) || (a[1] == m[1] && a[2] <= m[2]))
  }'
}

if [[ -x "$bin_dir/ffmpeg" && -x "$bin_dir/ffprobe" ]] \
  && [[ -f "$target_stamp" && "$(<"$target_stamp")" == "$deployment_target" ]] \
  && deployment_is_compatible "$bin_dir/ffmpeg" \
  && deployment_is_compatible "$bin_dir/ffprobe"; then
  finish_build
  exit 0
fi

rm -f "$bin_dir/ffmpeg" "$bin_dir/ffprobe"

cd "$source_root/lame-$lame_version"
make distclean >/dev/null 2>&1 || true
./configure \
  --prefix="$prefix" \
  --disable-shared \
  --enable-static \
  --disable-frontend
make -j"$build_jobs"
make install

cd "$source_root/ffmpeg-$ffmpeg_version"
make distclean >/dev/null 2>&1 || true
./configure \
  --prefix="$prefix" \
  --cc=clang \
  --disable-autodetect \
  --disable-shared \
  --enable-static \
  --disable-gpl \
  --disable-nonfree \
  --disable-network \
  --disable-doc \
  --disable-debug \
  --disable-avdevice \
  --disable-ffplay \
  --enable-libmp3lame \
  --extra-cflags="-I$prefix/include" \
  --extra-ldflags="-L$prefix/lib" \
  --extra-libs="-lm"
make -j"$build_jobs" ffmpeg ffprobe

cp ffmpeg ffprobe "$bin_dir/"

finish_build
