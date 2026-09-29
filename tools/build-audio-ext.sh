#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Builds the OpenQBORG audio GDExtension (FFmpeg decoder for AAC, Opus, FLAC,
# WMA, ...) into shared/openqborg_audio/bin/, used by both projects.
#
#   tools/build-audio-ext.sh           link the system FFmpeg (local use)
#   tools/build-audio-ext.sh --lgpl    link and bundle the LGPL-only FFmpeg from
#                                      tools/build-ffmpeg-lgpl.sh (releases)
#
# Needs CMake, a C++17 compiler and pkg-config; godot-cpp's binding generator
# also needs Python at build time. FFmpeg is always linked dynamically.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/shared/openqborg_audio/bin"
git -C "$ROOT" submodule update --init third_party/godot-cpp
extra=()
if [[ "${1:-}" == "--lgpl" ]]; then
	PREFIX="$ROOT/build/ffmpeg-lgpl/prefix"
	[[ -d "$PREFIX/lib" ]] || "$ROOT/tools/build-ffmpeg-lgpl.sh"
	export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"
	export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"
	extra+=(-DOQB_BUNDLE_FFMPEG=ON)
	rm -rf "$ROOT/build/audio"
fi
gen=()
command -v ninja >/dev/null && gen=(-G Ninja)
cmake -S "$ROOT/extensions/openqborg_audio" -B "$ROOT/build/audio" -DCMAKE_BUILD_TYPE=Release "${gen[@]}" "${extra[@]}"
cmake --build "$ROOT/build/audio" -j"$(nproc 2>/dev/null || echo 4)"
if [[ "${1:-}" == "--lgpl" ]]; then
	# Ship the exact sonames next to the extension; $ORIGIN rpath finds them.
	for lib in avformat avcodec swresample avutil; do
		cp -a "$PREFIX"/lib/lib$lib.so.* "$BIN/"
	done
	install -m 644 "$ROOT/build/ffmpeg-lgpl/"ffmpeg-*/COPYING.LGPLv2.1 "$BIN/FFMPEG-LICENSE.LGPLv2.1.txt"
	echo "FFmpeg (LGPL-2.1+) source: https://ffmpeg.org/releases/ ; configure line in build/ffmpeg-lgpl" > "$BIN/FFMPEG-SOURCE.txt"
fi
ls -1 "$BIN"
