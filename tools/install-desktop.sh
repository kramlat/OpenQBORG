#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Registers OpenQBORG with the desktop for the current user: borg:// and
# borgs:// links and .borg files (with their own icon) open in the player,
# and .borg files can also be opened with the editor.
#
#   tools/install-desktop.sh            the built copy in build/linux/ if there is
#                                       one, else run this checkout via `godot`
#   tools/install-desktop.sh --built    the built copy (error if not built)
#   tools/install-desktop.sh --source   run this checkout via `godot`
#   tools/install-desktop.sh BIN_DIR    openqborg-player/-editor in BIN_DIR
#
# For a system-wide install in /opt/openqborg, use tools/install-system.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DATA="${XDG_DATA_HOME:-$HOME/.local/share}"
GODOT="${GODOT:-$(command -v godot-mono || command -v godot || command -v godot4 || true)}"

bin_dir="${1:-}"
case "$bin_dir" in
	--built) bin_dir="$ROOT/build/linux" ;;
	--source) bin_dir="" ;;
	"") [[ -x "$ROOT/build/linux/openqborg-player" ]] && bin_dir="$ROOT/build/linux" ;;
esac
if [[ -n "$bin_dir" ]]; then
	bin_dir="$(cd "$bin_dir" && pwd)"
	[[ -x "$bin_dir/openqborg-player" ]] || { echo "no openqborg-player in $bin_dir (tools/build-release.sh)" >&2; exit 1; }
	player_exec="$bin_dir/openqborg-player"
	editor_exec="$bin_dir/openqborg-editor"
	player_icon="$bin_dir/player.svg"
	editor_icon="$bin_dir/editor.svg"
	[[ -f "$player_icon" ]] || player_icon=openqborg-player
	[[ -f "$editor_icon" ]] || editor_icon=openqborg-editor
else
	[[ -n "$GODOT" ]] || { echo "godot not found in PATH" >&2; exit 1; }
	player_exec="$GODOT --path $ROOT/player --"
	editor_exec="$GODOT --path $ROOT/editor --"
	player_icon="$ROOT/player/icon.svg"
	editor_icon="$ROOT/editor/icon.svg"
fi

icons="$DATA/icons/hicolor/scalable"
install -d "$DATA/applications" "$DATA/mime/packages" "$icons/apps" "$icons/mimetypes"
sed -e "s|@EXEC@|$player_exec|" -e "s|@ICON@|$player_icon|" "$ROOT/dist/linux/openqborg-player.desktop" > "$DATA/applications/openqborg-player.desktop"
sed -e "s|@EXEC@|$editor_exec|" -e "s|@ICON@|$editor_icon|" "$ROOT/dist/linux/openqborg-editor.desktop" > "$DATA/applications/openqborg-editor.desktop"
install -m 644 "$ROOT/dist/linux/openqborg.xml" "$DATA/mime/packages/openqborg.xml"
install -m 644 "$ROOT/player/icon.svg" "$icons/apps/openqborg-player.svg"
install -m 644 "$ROOT/editor/icon.svg" "$icons/apps/openqborg-editor.svg"
install -m 644 "$ROOT/dist/icons/application-x-qborg.svg" "$icons/mimetypes/application-x-qborg.svg"

update-mime-database "$DATA/mime" >/dev/null 2>&1 || true
update-desktop-database "$DATA/applications" >/dev/null 2>&1 || true
gtk-update-icon-cache -q -t "$DATA/icons/hicolor" >/dev/null 2>&1 || true
# KDE (Dolphin, Plasma) reads associations from its own service cache.
for kb in kbuildsycoca6 kbuildsycoca5; do
	command -v "$kb" >/dev/null && { "$kb" >/dev/null 2>&1 || true; break; }
done
for scheme in borg borgs; do
	xdg-mime default openqborg-player.desktop "x-scheme-handler/$scheme" 2>/dev/null || true
done
xdg-mime default openqborg-player.desktop application/x-qborg 2>/dev/null || true
echo "Registered borg://, borgs:// and .borg with OpenQBORG Player ($player_exec)."
