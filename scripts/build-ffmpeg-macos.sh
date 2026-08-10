#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
build_root="$repo_root/build/dependencies"
source_root="$build_root/src"
prefix="$build_root/prefix"
bin_dir="$build_root/bin"
ffmpeg_version="8.0.1"
lame_version="3.100"

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
  cp "$repo_root/LICENSE" "$build_root/licenses/Demucs-model-MIT.txt"
  echo "Built self-contained FFmpeg tools in $bin_dir"
}

if [[ -x "$bin_dir/ffmpeg" && -x "$bin_dir/ffprobe" ]]; then
  finish_build
  exit 0
fi

cd "$source_root/lame-$lame_version"
./configure \
  --prefix="$prefix" \
  --disable-shared \
  --enable-static \
  --disable-frontend
make -j"$(sysctl -n hw.ncpu)"
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
make -j"$(sysctl -n hw.ncpu)" ffmpeg ffprobe

cp ffmpeg ffprobe "$bin_dir/"

finish_build
