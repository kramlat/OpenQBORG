#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Installs the built OpenQBORG (build/linux, from tools/build-release.sh)
# system-wide. Asks for your password (sudo, or pkexec without a terminal).
#
#   tools/install-system.sh               install / update /opt/openqborg
#   tools/install-system.sh --uninstall   remove it again
#
# Layout:
#   /opt/openqborg/                        player, editor, runtime, examples, icons
#   /usr/local/bin/openqborg-{player,editor}
#   /usr/local/share/applications/         .desktop entries (borg://, borgs://, .borg)
#   /usr/local/share/mime/packages/        application/x-qborg
#   /usr/local/share/icons/hicolor/        app and .borg document icons
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PREFIX="/opt/openqborg"
LOCAL="/usr/local"
BUILD="$ROOT/build/linux"
USER_DATA="${XDG_DATA_HOME:-$HOME/.local/share}"

# --- privilege helper -----------------------------------------------------------

as_root() {
	if [[ $EUID -eq 0 ]]; then
		"$@"
	elif [[ -t 0 ]] && command -v sudo >/dev/null; then
		sudo "$@"
	elif command -v pkexec >/dev/null; then
		pkexec "$@"
	else
		echo "Need root: run this from a terminal with sudo available." >&2
		exit 1
	fi
}

# Everything that needs root runs as one script, so you are asked once.
root_install() {
	local build="$1" prefix="$2" local_dir="$3" root="$4"
	set -euo pipefail
	echo "Installing into $prefix ..."
	mkdir -p "$(dirname "$prefix")"
	rm -rf "$prefix.new"
	cp -a "$build" "$prefix.new"
	chown -R root:root "$prefix.new"
	find "$prefix.new" -type d -exec chmod 755 {} +
	find "$prefix.new" -type f -exec chmod 644 {} +
	chmod 755 "$prefix.new/openqborg-player" "$prefix.new/openqborg-editor" "$prefix.new/gdcef_helper"
	find "$prefix.new" -name "*.so*" -exec chmod 755 {} +
	# Chromium's setuid sandbox helper must be root-owned and setuid.
	chmod 4755 "$prefix.new/chrome-sandbox"
	# Swap in atomically-ish so a running copy keeps working until restart.
	if [[ -d "$prefix" ]]; then
		rm -rf "$prefix.old"
		mv "$prefix" "$prefix.old"
	fi
	mv "$prefix.new" "$prefix"
	rm -rf "$prefix.old"

	install -d "$local_dir/bin" "$local_dir/share/applications" "$local_dir/share/mime/packages" \
		"$local_dir/share/icons/hicolor/scalable/apps" "$local_dir/share/icons/hicolor/scalable/mimetypes"
	ln -sfn "$prefix/openqborg-player" "$local_dir/bin/openqborg-player"
	ln -sfn "$prefix/openqborg-editor" "$local_dir/bin/openqborg-editor"
	sed -e "s|@EXEC@|$prefix/openqborg-player|" -e "s|@ICON@|$prefix/player.svg|" "$root/dist/linux/openqborg-player.desktop" \
		> "$local_dir/share/applications/openqborg-player.desktop"
	sed -e "s|@EXEC@|$prefix/openqborg-editor|" -e "s|@ICON@|$prefix/editor.svg|" "$root/dist/linux/openqborg-editor.desktop" \
		> "$local_dir/share/applications/openqborg-editor.desktop"
	chmod 644 "$local_dir"/share/applications/openqborg-*.desktop
	install -m 644 "$root/dist/linux/openqborg.xml" "$local_dir/share/mime/packages/openqborg.xml"
	# Theme icons come from the copies shipped in the package.
	install -m 644 "$prefix/player.svg" "$local_dir/share/icons/hicolor/scalable/apps/openqborg-player.svg"
	install -m 644 "$prefix/editor.svg" "$local_dir/share/icons/hicolor/scalable/apps/openqborg-editor.svg"
	install -m 644 "$prefix/application-x-qborg.svg" \
		"$local_dir/share/icons/hicolor/scalable/mimetypes/application-x-qborg.svg"
	update-mime-database "$local_dir/share/mime" >/dev/null 2>&1 || true
	update-desktop-database "$local_dir/share/applications" >/dev/null 2>&1 || true
	gtk-update-icon-cache -q -t "$local_dir/share/icons/hicolor" >/dev/null 2>&1 || true
}

root_uninstall() {
	local prefix="$1" local_dir="$2"
	set -euo pipefail
	rm -rf "$prefix"
	rm -f "$local_dir/bin/openqborg-player" "$local_dir/bin/openqborg-editor" \
		"$local_dir"/share/applications/openqborg-{player,editor}.desktop \
		"$local_dir/share/mime/packages/openqborg.xml" \
		"$local_dir"/share/icons/hicolor/scalable/apps/openqborg-{player,editor}.svg \
		"$local_dir/share/icons/hicolor/scalable/mimetypes/application-x-qborg.svg"
	update-mime-database "$local_dir/share/mime" >/dev/null 2>&1 || true
	update-desktop-database "$local_dir/share/applications" >/dev/null 2>&1 || true
	gtk-update-icon-cache -q -t "$local_dir/share/icons/hicolor" >/dev/null 2>&1 || true
}

# A per-user registration (tools/install-desktop.sh) would shadow the system
# entries; remove ours, and only ours.
remove_user_registration() {
	local f
	for f in "$USER_DATA"/applications/openqborg-{player,editor}.desktop; do
		if [[ -f "$f" ]] && grep -q "OpenQBORG" "$f"; then
			rm -f "$f"
			echo "Removed per-user entry $f"
		fi
	done
	if [[ -f "$USER_DATA/mime/packages/openqborg.xml" ]]; then
		rm -f "$USER_DATA/mime/packages/openqborg.xml"
		update-mime-database "$USER_DATA/mime" >/dev/null 2>&1 || true
	fi
	update-desktop-database "$USER_DATA/applications" >/dev/null 2>&1 || true
}

refresh_desktop() {
	for kb in kbuildsycoca6 kbuildsycoca5; do
		command -v "$kb" >/dev/null && { "$kb" >/dev/null 2>&1 || true; break; }
	done
}

# --- main -----------------------------------------------------------------------

if [[ "${1:-}" == "--uninstall" ]]; then
	echo "Removing OpenQBORG from $PREFIX (asks for your password) ..."
	as_root bash -c "$(declare -f root_uninstall); root_uninstall '$PREFIX' '$LOCAL'"
	refresh_desktop
	echo "OpenQBORG uninstalled."
	exit 0
fi

if [[ ! -x "$BUILD/openqborg-player" ]]; then
	echo "No build found; running tools/build-release.sh first ..."
	"$ROOT/tools/build-release.sh"
fi

echo "OpenQBORG will be installed to $PREFIX with launchers in $LOCAL/bin."
echo "Administrator rights are needed; you'll be asked for your password."
as_root bash -c "$(declare -f root_install); root_install '$BUILD' '$PREFIX' '$LOCAL' '$ROOT'"

remove_user_registration
for scheme in borg borgs; do
	xdg-mime default openqborg-player.desktop "x-scheme-handler/$scheme" 2>/dev/null || true
done
xdg-mime default openqborg-player.desktop application/x-qborg 2>/dev/null || true
refresh_desktop

echo
echo "Installed OpenQBORG $(du -sh "$PREFIX" | cut -f1) in $PREFIX."
echo "Run it from your application menu, as openqborg-player / openqborg-editor,"
echo "or by opening a .borg file or a borg:// / borgs:// link."
