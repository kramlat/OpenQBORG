# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 Mark Toman and OpenQBORG contributors
class_name Bookmarks
extends RefCounted
## The player's bookmarks, kept in user://bookmarks.cfg. Defaults (the example
## worlds, and CYBERWORLD worlds that survive online in the Wayback Machine)
## are added once each: a default the user removes stays removed, and defaults
## added in later versions still reach existing bookmark files.

signal changed

const PATH := "user://bookmarks.cfg"
const EXAMPLES_FOLDER := "Example Worlds"
const ONLINE_FOLDER := "Online: Surviving CYBERWORLD Worlds"
const EXAMPLES := [["Hello QBORG (classic courtyard)", "hello.borg"],
		["The Sprawl (128×128 island)", "sprawl.borg"],
		["The Orb Vault (scripted)", "puzzle.borg"],
		["The Theater (web surfaces)", "theater.borg"]]
## Worlds whose .borg files and assets were archived. Zeta Quest is complete;
## the archive missed some Olympiad floors, walls and sprites. id_ asks the Wayback
## Machine for the original bytes, and it picks the capture nearest the year.
const WAYBACK := "borgs://web.archive.org/web/%sid_/%s"
const ONLINE := [
		["Zeta Quest 3D: Intro (Warner Bros., 2001)", "2001", "http://www2.warnerbros.com:80/zeta/borgs/intro.borg"],
		["Zeta Quest 3D: Guard Room", "2001", "http://www2.warnerbros.com:80/zeta/borgs/guard.borg"],
		["Zeta Quest 3D: Forest", "2001", "http://www2.warnerbros.com:80/zeta/borgs/forest.borg"],
		["Zeta Quest 3D: Office", "2001", "http://www2.warnerbros.com:80/zeta/borgs/office.borg"],
		["Zeta Quest 3D: Lab", "2001", "http://www2.warnerbros.com:80/zeta/borgs/iu8labA.borg"],
		["CYBERWORLD Olympiad (2002, partly archived)", "2002", "http://www.cyberworldcorp.com:80/Gallery/worlds/olympiad/cw_olympiad.borg"],
		["Olympiad: Gymnastics", "2002", "http://www.cyberworldcorp.com:80/Gallery/worlds/olympiad/cw_gymnastics.borg"],
		["Olympiad: Swimming Pool", "2002", "http://www.cyberworldcorp.com:80/Gallery/worlds/olympiad/cw_swimming_pool.borg"],
		["Olympiad: Track and Field", "2002", "http://www.cyberworldcorp.com:80/Gallery/worlds/olympiad/cw_trackandfield.borg"]]
## Worlds kept whole in Internet Archive items (served from inside their ZIPs).
const ARCHIVE_ITEMS := [
		["Pokémon 2000 Adventure (Warner Bros., 2000)",
			"borgs://archive.org/download/CyberworldAssets/p2kresurrected%20%2B%20fixed.zip/game/borgs/intro.borg"]]

## [{title, url, folder}] in menu order; folder "" is the top level.
var items: Array[Dictionary] = []
## Keys of every default ever added, so removed ones aren't added back.
var _seeded := PackedStringArray()
var _dirty := false


func load_or_seed() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(PATH) == OK:
		for entry in cfg.get_value("bookmarks", "items", []):
			if entry is Dictionary and entry.has("url"):
				items.append({"title": str(entry.get("title", entry.url)), "url": str(entry.url),
						"folder": str(entry.get("folder", ""))})
		_seeded = PackedStringArray(cfg.get_value("bookmarks", "seeded", []))
	var defs := defaults()
	var added := false
	if _seeded.is_empty() and not items.is_empty():
		# A file from before folders: what's there already counts as seeded,
		# and defaults in it move into their folder.
		for b in items:
			for d in defs:
				if _is_default(b, d):
					b.folder = d.folder
					_seeded.append(d.key)
		added = true
	for d in defs:
		if not d.key in _seeded:
			_seeded.append(d.key)
			if not items.any(func(b: Dictionary) -> bool: return _is_default(b, d)):
				items.append({"title": d.title, "url": d.url, "folder": d.folder})
			added = true
	if added or not FileAccess.file_exists(PATH):
		save()


## The default bookmarks: examples (when a copy can be found) and online worlds.
static func defaults() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var dir := examples_dir()
	if not dir.is_empty():
		for e in EXAMPLES:
			if FileAccess.file_exists(dir.path_join(e[1])):
				out.append({"title": e[0], "url": "file://" + dir.path_join(e[1]), "folder": EXAMPLES_FOLDER,
						"key": "example:" + e[1]})
	for o in ONLINE:
		out.append({"title": o[0], "url": WAYBACK % [o[1], o[2]], "folder": ONLINE_FOLDER, "key": o[2]})
	for a in ARCHIVE_ITEMS:
		out.append({"title": a[0], "url": a[1], "folder": ONLINE_FOLDER, "key": a[1]})
	return out


## A bookmark is a default if it has its address or, for an example, if it
## points at the same example in any copy (checkout, build, /opt).
static func _is_default(b: Dictionary, d: Dictionary) -> bool:
	if b.url == d.url:
		return true
	var key: String = d.key
	return key.begins_with("example:") and b.url.begins_with("file://") \
			and b.url.ends_with("/examples/borgs/" + key.trim_prefix("example:"))


## examples/borgs next to the built binary, or in the source checkout.
static func examples_dir() -> String:
	for base: String in [OS.get_executable_path().get_base_dir(),
			ProjectSettings.globalize_path("res://").path_join("..")]:
		var d := base.path_join("examples/borgs").simplify_path()
		if FileAccess.file_exists(d.path_join("hello.borg")):
			return d
	return ""


## Folder names in first-seen order.
func folders() -> PackedStringArray:
	var out := PackedStringArray()
	for b in items:
		if not b.folder in out:
			out.append(b.folder)
	return out


## Writes the file now. If it can't be written the change stays pending and
## flush() (called on exit) tries again.
func save() -> bool:
	var cfg := ConfigFile.new()
	cfg.set_value("bookmarks", "items", items)
	cfg.set_value("bookmarks", "seeded", _seeded)
	# Write beside the file and rename, so a crash mid-save can't lose them.
	var tmp := PATH + ".new"
	var ok := cfg.save(tmp) == OK and DirAccess.rename_absolute(
			ProjectSettings.globalize_path(tmp), ProjectSettings.globalize_path(PATH)) == OK
	_dirty = not ok
	changed.emit()
	return ok


## Saves any change that hasn't reached the disk yet.
func flush() -> void:
	if _dirty:
		save()


func index_of(url: String) -> int:
	for i in items.size():
		if items[i].url == url:
			return i
	return -1


func add(title: String, url: String, folder := "") -> void:
	if url.is_empty() or index_of(url) >= 0:
		return
	items.append({"title": title if not title.is_empty() else url, "url": url, "folder": folder})
	save()


func remove(url: String) -> void:
	var i := index_of(url)
	if i >= 0:
		items.remove_at(i)
		save()
