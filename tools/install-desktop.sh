#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Registers OpenQBORG with the desktop for the current user: borg:// and
# borgs:// links and .borg files open in the player, .borg files can be
# opened with the editor.
#
#   tools/install-desktop.sh            run from this checkout via `godot`
#   tools/install-desktop.sh BIN_DIR    use exported openqborg-player/-editor in BIN_DIR
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DATA="${XDG_DATA_HOME:-$HOME/.local/share}"
GODOT="$(command -v godot || command -v godot4 || true)"

if [[ -n "${1:-}" ]]; then
	player_exec="$1/openqborg-player"
	editor_exec="$1/openqborg-editor"
else
	[[ -n "$GODOT" ]] || { echo "godot not found in PATH" >&2; exit 1; }
	player_exec="$GODOT --path $ROOT/player --"
	editor_exec="$GODOT --path $ROOT/editor --"
fi

install -d "$DATA/applications" "$DATA/mime/packages" "$DATA/icons/hicolor/scalable/apps"
sed "s|@EXEC@|$player_exec|" "$ROOT/dist/linux/openqborg-player.desktop" > "$DATA/applications/openqborg-player.desktop"
sed "s|@EXEC@|$editor_exec|" "$ROOT/dist/linux/openqborg-editor.desktop" > "$DATA/applications/openqborg-editor.desktop"
install -m 644 "$ROOT/dist/linux/openqborg.xml" "$DATA/mime/packages/openqborg.xml"
install -m 644 "$ROOT/player/icon.svg" "$DATA/icons/hicolor/scalable/apps/openqborg-player.svg"
install -m 644 "$ROOT/editor/icon.svg" "$DATA/icons/hicolor/scalable/apps/openqborg-editor.svg"

update-mime-database "$DATA/mime" >/dev/null 2>&1 || true
update-desktop-database "$DATA/applications" >/dev/null 2>&1 || true
for scheme in borg borgs; do
	xdg-mime default openqborg-player.desktop "x-scheme-handler/$scheme" || true
done
xdg-mime default openqborg-player.desktop application/x-qborg || true
echo "Registered borg://, borgs:// and .borg with OpenQBORG Player."
