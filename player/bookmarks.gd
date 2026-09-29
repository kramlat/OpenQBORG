# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 Mark Toman and OpenQBORG contributors
class_name Bookmarks
extends RefCounted
## The player's bookmarks, kept in user://bookmarks.cfg. On first run they
## are seeded with the example worlds, when a copy of examples/ can be found
## next to the checkout or the built player.

signal changed

const PATH := "user://bookmarks.cfg"
const EXAMPLES := [["Hello QBORG (classic courtyard)", "hello.borg"],
		["The Sprawl (128×128 island)", "sprawl.borg"],
		["The Orb Vault (scripted)", "puzzle.borg"]]

## [{title, url}] in menu order.
var items: Array[Dictionary] = []


func load_or_seed() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(PATH) == OK:
		for entry in cfg.get_value("bookmarks", "items", []):
			if entry is Dictionary and entry.has("url"):
				items.append({"title": str(entry.get("title", entry.url)), "url": str(entry.url)})
		return
	var dir := examples_dir()
	if not dir.is_empty():
		for e in EXAMPLES:
			items.append({"title": e[0], "url": "file://" + dir.path_join(e[1])})
	save()


## examples/borgs next to the built binary, or in the source checkout.
static func examples_dir() -> String:
	for base: String in [OS.get_executable_path().get_base_dir(),
			ProjectSettings.globalize_path("res://").path_join("..")]:
		var d := base.path_join("examples/borgs").simplify_path()
		if FileAccess.file_exists(d.path_join("hello.borg")):
			return d
	return ""


func save() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("bookmarks", "items", items)
	cfg.save(PATH)
	changed.emit()


func index_of(url: String) -> int:
	for i in items.size():
		if items[i].url == url:
			return i
	return -1


func add(title: String, url: String) -> void:
	if url.is_empty() or index_of(url) >= 0:
		return
	items.append({"title": title if not title.is_empty() else url, "url": url})
	save()


func remove(url: String) -> void:
	var i := index_of(url)
	if i >= 0:
		items.remove_at(i)
		save()
