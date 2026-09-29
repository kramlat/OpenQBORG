#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Builds the OpenQBORG media GDExtension (FFmpeg decoding for AAC, Opus, FLAC,
# WMA, ... audio and GIF/APNG/MJPEG animated textures) into
# shared/openqborg_media/bin/, used by both projects.
#
#   tools/build-media-ext.sh           link the system FFmpeg (local use)
#   tools/build-media-ext.sh --lgpl    link and bundle the LGPL-only FFmpeg from
#                                      tools/build-ffmpeg-lgpl.sh (releases)
#
# Needs CMake, a C++17 compiler and pkg-config; godot-cpp's binding generator
# also needs Python at build time. FFmpeg is always linked dynamically.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/shared/openqborg_media/bin"
git -C "$ROOT" submodule update --init third_party/godot-cpp
extra=()
if [[ "${1:-}" == "--lgpl" ]]; then
	PREFIX="$ROOT/build/ffmpeg-lgpl/prefix"
	# Rebuild when missing or from before swscale (picture decoding) was added.
	[[ -e "$PREFIX/lib/libswscale.so" ]] || "$ROOT/tools/build-ffmpeg-lgpl.sh"
	export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"
	export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"
	extra+=(-DOQB_BUNDLE_FFMPEG=ON)
	rm -rf "$ROOT/build/media"
fi
gen=()
command -v ninja >/dev/null && gen=(-G Ninja)
cmake -S "$ROOT/extensions/openqborg_media" -B "$ROOT/build/media" -DCMAKE_BUILD_TYPE=Release "${gen[@]}" "${extra[@]}"
cmake --build "$ROOT/build/media" -j"$(nproc 2>/dev/null || echo 4)"
if [[ "${1:-}" == "--lgpl" ]]; then
	# Ship the exact sonames next to the extension; $ORIGIN rpath finds them.
	for lib in avformat avcodec swresample swscale avutil; do
		cp -a "$PREFIX"/lib/lib$lib.so.* "$BIN/"
	done
	install -m 644 "$ROOT/build/ffmpeg-lgpl/"ffmpeg-*/COPYING.LGPLv2.1 "$BIN/FFMPEG-LICENSE.LGPLv2.1.txt"
	echo "FFmpeg (LGPL-2.1+) source: https://ffmpeg.org/releases/ ; configure line in build/ffmpeg-lgpl" > "$BIN/FFMPEG-SOURCE.txt"
fi
ls -1 "$BIN"
