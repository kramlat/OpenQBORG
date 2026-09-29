#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Builds runnable copies of the player and editor into build/linux/:
#
#   tools/build-release.sh              Linux x86_64
#
# Needs Godot export templates for your Godot version, the godot-cef addon
# (tools/fetch-assets.sh cef [--source]) and a SoundFont (fetch-assets.sh
# soundfont). The audio extension is (re)built against the LGPL-only FFmpeg,
# which is what a distributable copy must ship.
# Then: tools/install-desktop.sh --built  registers it for .borg/borg:// links.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT="${GODOT:-$(command -v godot || command -v godot4)}"
OUT="$ROOT/build/linux"

[[ -d "$ROOT/player/addons/godot_cef/bin" ]] || { echo "godot-cef missing: tools/fetch-assets.sh cef" >&2; exit 1; }
ls "$ROOT"/soundfonts/*.sf2 >/dev/null 2>&1 || echo "warning: no SoundFont; MIDI music will be silent (fetch-assets.sh soundfont)" >&2
if ! ls "$ROOT"/shared/openqborg_audio/bin/libavformat.so.* >/dev/null 2>&1; then
	"$ROOT/tools/build-audio-ext.sh" --lgpl
fi

# Distro packages (e.g. Arch) install templates system-wide, but Godot only
# looks in the user data dir. Link them in when the user path is free.
ver="$("$GODOT" --version | sed -E "s/^([0-9]+\.[0-9]+(\.[0-9]+)?\.[a-z0-9]+)\..*/\1/")"
user_tpl="${XDG_DATA_HOME:-$HOME/.local/share}/godot/export_templates/$ver"
for sys_tpl in /usr/share/godot/export_templates/$ver /usr/local/share/godot/export_templates/$ver; do
	if [[ ! -e "$user_tpl" && -f "$sys_tpl/linux_release.x86_64" ]]; then
		mkdir -p "$(dirname "$user_tpl")"
		ln -s "$sys_tpl" "$user_tpl"
		echo "Linked export templates: $user_tpl -> $sys_tpl"
	fi
done

mkdir -p "$OUT"
for app in player editor; do
	echo "Exporting $app ..."
	# Import first so a fresh checkout has its .godot cache and class list.
	"$GODOT" --headless --path "$ROOT/$app" --import >/dev/null 2>&1 || true
	"$GODOT" --headless --path "$ROOT/$app" --export-release "Linux" "$OUT/openqborg-$app"
done
rm -rf "$OUT/examples"
cp -a "$ROOT/examples" "$OUT/examples"
cp "$ROOT/LICENSE" "$ROOT/README.md" "$OUT/"
install -m 644 "$ROOT/dist/icons/application-x-qborg.svg" "$OUT/"
echo
echo "Built into $OUT ($(du -sh "$OUT" | cut -f1)). Register it with:"
echo "  tools/install-desktop.sh --built"
