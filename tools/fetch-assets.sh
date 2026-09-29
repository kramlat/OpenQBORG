#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Installs the large runtime assets that are not kept in git.
#
#   tools/fetch-assets.sh soundfont            GeneralUser GS -> soundfonts/
#   tools/fetch-assets.sh cef                 godot-cef addon -> player/addons/godot_cef,
#                                              from the newest upstream release <= contrib/
#   tools/fetch-assets.sh cef --source        build it from contrib/godot-cef (Rust, via mise)
#   tools/fetch-assets.sh cef DIR             copy it from another godot-cef checkout/build
#   tools/fetch-assets.sh ruffle             Ruffle Flash emulator (self-hosted web build) -> player/web/ruffle
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

fetch_ruffle() {
	# Ruffle publishes nightlies only; take the newest self-hosted web build.
	local dest="$ROOT/player/web/ruffle" url tmp
	url="$(curl -fsSL https://api.github.com/repos/ruffle-rs/ruffle/releases | sed -n "s/.*\"browser_download_url\": *\"\([^\"]*web-selfhosted.zip\)\".*/\1/p" | head -1)"
	[[ -n "$url" ]] || { echo "no Ruffle web build found" >&2; exit 1; }
	tmp="$(mktemp -d)"
	echo "Downloading $(basename "$url") ..."
	curl -fL --progress-bar -o "$tmp/ruffle.zip" "$url"
	rm -rf "$dest"
	mkdir -p "$dest"
	unzip -q "$tmp/ruffle.zip" -x "*.map" -d "$dest"
	rm -rf "$tmp"
	echo "Installed Ruffle into $dest ($(du -sh "$dest" | cut -f1))"
}

fetch_cef() {
	local src="${1:-}" dest="$ROOT/player/addons/godot_cef" plat
	plat="$(platform_dir)"
	if [[ "$src" == "--source" ]]; then
		build_cef_source
		src="$ROOT/contrib/godot-cef"
	fi
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
		# The newest release at or below the pinned contrib/godot-cef commit. When
		# the pin is past that release, only --source rebuilds the exact binaries.
		tag="$(git -C "$ROOT/contrib/godot-cef" describe --tags --abbrev=0 2>/dev/null || true)"
		if [[ -n "$tag" ]] && ! git -C "$ROOT/contrib/godot-cef" describe --tags --exact-match >/dev/null 2>&1; then
			echo "note: contrib/godot-cef is pinned past $tag; downloading $tag. For binaries that match the pinned source exactly, use: $0 cef --source"
		fi
		[[ -n "$tag" ]] || tag="$(curl -fsSL "https://api.github.com/repos/$CEF_REPO/releases/latest" | sed -n "s/.*\"tag_name\": *\"\([^\"]*\)\".*/\1/p" | head -1)"
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

build_cef_source() {
	# Rust nightly + export-cef-dir come from the submodule's mise.toml.
	local src="$ROOT/contrib/godot-cef" version
	git -C "$ROOT" submodule update --init contrib/godot-cef
	command -v mise >/dev/null || { echo "building godot-cef needs mise (https://mise.jdx.dev)" >&2; exit 1; }
	cd "$src"
	mise trust --quiet .
	mise install
	version="$(mise exec -- printenv CEF_VERSION)"
	if [[ -z "${CEF_PATH:-}" ]]; then
		# Reuse an installed runtime only if it is exactly the pinned version.
		for cand in /usr/share/CEF /usr/local/share/CEF "$HOME/.local/share/cef"; do
			if grep -q "cef_binary_${version}+" "$cand/archive.json" 2>/dev/null; then
				CEF_PATH="$cand"
				break
			fi
		done
	fi
	if [[ -z "${CEF_PATH:-}" ]]; then
		CEF_PATH="$ROOT/build/cef-runtime/$version"
		if [[ ! -f "$CEF_PATH/archive.json" ]]; then
			echo "Downloading the CEF $version runtime into $CEF_PATH ..."
			mkdir -p "$(dirname "$CEF_PATH")"
			# export-cef-dir --force REPLACES its target (and stages files in the
			# parent directory), so only ever point it at our own build folder.
			mise exec -- export-cef-dir --version "$version" --force "$CEF_PATH"
		fi
	fi
	export CEF_PATH
	export LD_LIBRARY_PATH="$CEF_PATH${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
	echo "Building godot-cef $(git describe --tags 2>/dev/null) against CEF $version ($CEF_PATH)..."
	mise exec -- cargo xtask bundle --release
	cd "$ROOT"
}

case "${1:-}" in
	soundfont) fetch_soundfont ;;
	cef) fetch_cef "${2:-}" ;;
	ruffle) fetch_ruffle ;;
	all) fetch_soundfont; fetch_ruffle; fetch_cef "${2:-}" ;;
	*) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
