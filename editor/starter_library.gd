# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 Mark Toman and OpenQBORG contributors
class_name StarterLibrary
extends RefCounted
## The editor's starter library: ready-made textures, sprites, sounds, music
## and templates (made by tools/make_examples.gd). It is laid out like a
## world folder (domains/, objects/, media/, scripts/, html/) with a
## library.json catalogue, so a new, unsaved world can preview straight from
## it. When a world is saved, whatever it uses from the library is copied
## into the world's own folders, keeping the world self-contained.

## Which world folder each kind of reference lives in.
const FOLDERS := {"flr": "domains", "cei": "domains", "wal": "domains", "nav": "domains",
		"emb": "domains", "bdp": "domains", "gtw": "domains", "gtw2": "domains",
		"gtw3": "domains", "spr": "objects", "wav": "media", "mid": "media", "js": "scripts"}

var dir := ""
var manifest := {}
var _thumbs := {}


## library/ next to the built editor, or editor/library in the checkout.
static func find_dir() -> String:
	for base: String in [OS.get_executable_path().get_base_dir(), ProjectSettings.globalize_path("res://")]:
		var d := base.path_join("library").simplify_path()
		if FileAccess.file_exists(d.path_join("library.json")):
			return d
	return ""


func load_library() -> bool:
	dir = find_dir()
	if dir.is_empty():
		return false
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(dir.path_join("library.json")))
	manifest = parsed if parsed is Dictionary else {}
	return not manifest.is_empty()


func available() -> bool:
	return not manifest.is_empty()


func base_url() -> String:
	return "file://" + dir + "/"


func path(folder: String, file: String) -> String:
	return dir.path_join(folder).path_join(file)


func floor_names() -> Array:
	return manifest.get("floors", {}).get("tiles", [])


func wall_names() -> Array:
	return manifest.get("walls", {}).get("strips", [])


## Points `level` at the library's floor tiles (all of them), the still JPEG
## set or the animated GIF set (same tiles, water/pad/lava moving).
func use_floors(level: BorgLevel, tag := "flr", animated := false) -> void:
	var offsets := PackedInt64Array()
	for i in floor_names().size():
		offsets.append(i * 256 * 256)
	level.set_ext_cfil(tag, manifest.floors.get("animated", manifest.floors.file) if animated else manifest.floors.file, offsets)


## Points `level` at the library's wall strips (256 tall, 1024 wide).
func use_walls(level: BorgLevel, animated := false) -> void:
	var offsets := PackedInt64Array()
	for i in wall_names().size():
		offsets.append(i * 256 * 1024)
	level.set_ext_cfil("wal", manifest.walls.get("animated", manifest.walls.file) if animated else manifest.walls.file, offsets)


func uses_library_floors(level: BorgLevel, tag := "flr") -> bool:
	var f: Dictionary = manifest.get("floors", {})
	return level.ext_cfil(tag).get("href", "") in [f.get("file", "?"), f.get("animated", "?")]


func uses_animated_floors(level: BorgLevel, tag := "flr") -> bool:
	return level.ext_cfil(tag).get("href", "") == manifest.get("floors", {}).get("animated", "?")


func uses_library_walls(level: BorgLevel) -> bool:
	var w: Dictionary = manifest.get("walls", {})
	return level.ext_cfil("wal").get("href", "") in [w.get("file", "?"), w.get("animated", "?")]


func uses_animated_walls(level: BorgLevel) -> bool:
	return level.ext_cfil("wal").get("href", "") == manifest.get("walls", {}).get("animated", "?")


func set_backdrop(level: BorgLevel, entry: Dictionary) -> void:
	var bdp := level.ensure_ext("bdp")
	bdp.items = [{"kind": "file", "href": entry.file, "text": ""}]
	bdp.attrs["BC"] = entry.get("color", "0")
	bdp.attrs["POS"] = "%x" % (int(entry.get("pos", 0)) & 0xffffffff)


## A new world that's ready to paint: library floors and walls, grass
## everywhere, a brick border, the sky backdrop and a start in the middle.
func furnish(level: BorgLevel) -> void:
	use_floors(level)
	use_walls(level)
	for y in level.height:
		for x in level.width:
			level.set_cell("flr", x, y, 0)
			if x == 0 or y == 0 or x == level.width - 1 or y == level.height - 1:
				level.set_cell("hgt", x, y, 64)
				level.set_cell("wal", x, y, 1)
	var skies: Array = manifest.get("backdrops", [])
	if not skies.is_empty():
		set_backdrop(level, skies[0])
	level.start_pos[2] = 20


## Copies every file `level` references that exists in the library but not
## yet in the world folder `world_dir`. Returns the files copied.
func copy_used(level: BorgLevel, world_dir: String) -> PackedStringArray:
	var copied := PackedStringArray()
	for entry in level.ext:
		var folder: String = FOLDERS.get(entry.tag, "")
		if folder.is_empty():
			continue
		for item in entry.items:
			var href: String = item.href
			if href.is_empty():
				continue
			var src := path(folder, href)
			var dst := world_dir.path_join(folder).path_join(href)
			if FileAccess.file_exists(src) and not FileAccess.file_exists(BorgUrl.resolve_case(dst)):
				DirAccess.make_dir_recursive_absolute(dst.get_base_dir())
				if DirAccess.copy_absolute(src, dst) == OK:
					copied.append(folder.path_join(href))
	return copied


## Copies a library file (html/…, scripts/…) into the world, unless the world
## already has one by that name.
func copy_file(folder: String, file: String, world_dir: String) -> bool:
	var dst := world_dir.path_join(folder).path_join(file)
	if FileAccess.file_exists(dst):
		return false
	DirAccess.make_dir_recursive_absolute(dst.get_base_dir())
	return DirAccess.copy_absolute(path(folder, file), dst) == OK


# --- Thumbnails ---------------------------------------------------------------------

const THUMB := 48


func sprite_thumb(file: String) -> Texture2D:
	var key := "spr:" + file
	if not _thumbs.has(key):
		var s := CWSprite.decode(FileAccess.get_file_as_bytes(path("objects", file)), file)
		var tex: Texture2D = null
		if s != null:
			var frame := s.image.get_region(Rect2i(0, 0, s.image.get_width(), mini(s.image.get_height(), s.cell_height)))
			tex = _fit(frame)
		_thumbs[key] = tex
	return _thumbs[key]


func floor_thumb(index: int) -> Texture2D:
	var key := "flr:%d" % index
	if not _thumbs.has(key):
		var img := BorgWorld.decode_image(FileAccess.get_file_as_bytes(path("domains", manifest.floors.file)))
		_thumbs[key] = _fit(img.get_region(Rect2i(0, index * 256, 256, 256))) if img != null else null
	return _thumbs[key]


func wall_thumb(index: int) -> Texture2D:
	var key := "wal:%d" % index
	if not _thumbs.has(key):
		var img := BorgWorld.decode_image(FileAccess.get_file_as_bytes(path("domains", manifest.walls.file)))
		var tex: Texture2D = null
		if img != null:
			var strip := img.get_region(Rect2i(0, index * 256, 256, 256))
			strip.rotate_90(CLOCKWISE)
			tex = _fit(strip)
		_thumbs[key] = tex
	return _thumbs[key]


func backdrop_thumb(file: String) -> Texture2D:
	var key := "bck:" + file
	if not _thumbs.has(key):
		var img := BorgWorld.decode_image(FileAccess.get_file_as_bytes(path("domains", file)))
		_thumbs[key] = _fit(img.get_region(Rect2i(0, 0, img.get_height(), img.get_height()))) if img != null else null
	return _thumbs[key]


static func _fit(img: Image) -> Texture2D:
	img = img.duplicate()
	img.convert(Image.FORMAT_RGBA8)
	var s := float(THUMB) / maxf(img.get_width(), img.get_height())
	img.resize(maxi(1, int(img.get_width() * s)), maxi(1, int(img.get_height() * s)), Image.INTERPOLATE_BILINEAR)
	return ImageTexture.create_from_image(img)
