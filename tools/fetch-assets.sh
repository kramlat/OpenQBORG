#!/usr/bin/env bash
# Installs the large runtime assets that are not kept in git.
#
#   tools/fetch-assets.sh soundfont            GeneralUser GS -> soundfonts/
#   tools/fetch-assets.sh cef [godot-cef dir]  godot-cef addon -> player/addons/godot_cef
#                                              (copied from a local checkout/build if given,
#                                              otherwise the latest upstream release)
#   tools/fetch-assets.sh all
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SF_URL="https://github.com/mrbumpy409/GeneralUser-GS/raw/main/GeneralUser-GS.sf2"
CEF_REPO="dsh0416/godot-cef"

platform_dir() {
	case "$(uname -s)-$(uname -m)" in
		Linux-x86_64) echo "x86_64-unknown-linux-gnu" ;;
		Linux-aarch64) echo "aarch64-unknown-linux-gnu" ;;
		Darwin-*) echo "universal-apple-darwin" ;;
		*) echo "unsupported platform: $(uname -sm)" >&2; exit 1 ;;
	esac
}

fetch_soundfont() {
	local out="$ROOT/soundfonts/GeneralUser-GS.sf2"
	if [[ -f "$out" ]]; then
		echo "SoundFont already present: $out"
		return
	fi
	echo "Downloading GeneralUser GS (~31 MB, freely redistributable, see its LICENSE)..."
	curl -fL --progress-bar -o "$out.part" "$SF_URL"
	mv "$out.part" "$out"
	echo "Installed $out"
}

fetch_cef() {
	local src="${1:-}" dest="$ROOT/player/addons/godot_cef" plat
	plat="$(platform_dir)"
	if [[ -n "$src" ]]; then
		[[ -d "$src/addons/godot_cef" ]] || { echo "no addons/godot_cef in $src" >&2; exit 1; }
		echo "Copying godot-cef addon ($plat) from $src ..."
		rm -rf "$dest"
		mkdir -p "$dest/bin"
		# Everything except other platforms' binaries.
		(cd "$src/addons/godot_cef" && find . -path ./bin -prune -o -type f -print) |
			while read -r f; do install -D -m 644 "$src/addons/godot_cef/$f" "$dest/$f"; done
		cp -a "$src/addons/godot_cef/bin/$plat" "$dest/bin/"
	else
		local tmp tag
		tmp="$(mktemp -d)"
		trap 'rm -rf "$tmp"' RETURN
		tag="$(curl -fsSL "https://api.github.com/repos/$CEF_REPO/releases/latest" | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1)"
		echo "Downloading godot-cef $tag (the release zip holds every platform, ~1 GB)..."
		curl -fL --progress-bar -o "$tmp/cef.zip" \
			"https://github.com/$CEF_REPO/releases/download/$tag/godot_cef-$tag.zip"
		rm -rf "$dest"
		unzip -q "$tmp/cef.zip" "addons/godot_cef/*" -x "addons/godot_cef/bin/*" -d "$tmp/x"
		unzip -q "$tmp/cef.zip" "addons/godot_cef/bin/$plat/*" -d "$tmp/x"
		mv "$tmp/x/addons/godot_cef" "$dest"
	fi
	echo "Installed godot-cef into $dest ($(du -sh "$dest" | cut -f1))"
}

case "${1:-}" in
	soundfont) fetch_soundfont ;;
	cef) fetch_cef "${2:-}" ;;
	all) fetch_soundfont; fetch_cef "${2:-}" ;;
	*) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
