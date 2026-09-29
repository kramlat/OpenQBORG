#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Builds a small LGPL-only FFmpeg (shared libraries, audio decoding only) for
# bundling with OpenQBORG releases. Distribution builds must use this rather
# than a system FFmpeg, which is often configured with --enable-gpl.
#
#   tools/build-ffmpeg-lgpl.sh [version]     -> build/ffmpeg-lgpl/prefix
#
# Only FFmpeg's own decoders are enabled (no external codec libraries), with
# --disable-gpl --disable-nonfree, so the result is LGPL-2.1-or-later.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:-8.0}"
WORK="$ROOT/build/ffmpeg-lgpl"
PREFIX="$WORK/prefix"
mkdir -p "$WORK"
cd "$WORK"
if [[ ! -d "ffmpeg-$VERSION" ]]; then
	curl -fL --progress-bar -o "ffmpeg-$VERSION.tar.xz" "https://ffmpeg.org/releases/ffmpeg-$VERSION.tar.xz"
	tar xf "ffmpeg-$VERSION.tar.xz"
fi
cd "ffmpeg-$VERSION"
DECODERS="aac,aac_latm,mp1,mp2,mp3,mp3float,opus,vorbis,flac,alac,wmav1,wmav2,wmapro,wmalossless,
ape,wavpack,tta,speex,amrnb,amrwb,gsm,gsm_ms,ac3,eac3,dca,truehd,mlp,pcm_*,adpcm_*,
dsd_*,qdmc,qdm2,atrac3,atrac3p,cook,ra_144,ra_288,nellymoser,sipr,g722,g723_1,g726,g729"
DEMUXERS="aac,ac3,aiff,amr,ape,asf,au,caf,dts,eac3,flac,mov,mp3,ogg,matroska,wav,w64,wv,
tta,truehd,voc,xwma,rm,mpc,mpc8,gsm,avi,mpegts,mpegps,flv,nut,dsf,sox,latm,loas"
PARSERS="aac,aac_latm,ac3,flac,mpegaudio,opus,vorbis,dca,mlp,gsm,amr"
./configure --prefix="$PREFIX" \
	--disable-gpl --disable-nonfree --disable-version3 \
	--enable-shared --disable-static --disable-programs --disable-doc \
	--disable-everything --disable-autodetect --disable-network \
	--disable-avdevice --disable-avfilter --disable-swscale \
	--enable-avformat --enable-avcodec --enable-swresample \
	--enable-decoder="${DECODERS//$'\n'/}" --enable-demuxer="${DEMUXERS//$'\n'/}" \
	--enable-parser="$PARSERS" --enable-protocol=file \
	--extra-ldflags='-Wl,-rpath,$$ORIGIN'
make -j"$(nproc 2>/dev/null || echo 4)"
make install
echo "LGPL FFmpeg installed to $PREFIX"
