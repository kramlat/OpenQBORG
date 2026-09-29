# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 Mark Toman and OpenQBORG contributors
class_name BorgLevel
extends RefCounted
## In-memory model of a CYBERWORLD .borg level (XML, VER 3.0).
##
## A classic level is a 16x16 tile grid. Each <map> layer is stored in the file
## as a run-length encoded list of hex tokens: the last two hex digits are the
## tile value, the digits before them are the repeat count ("10000" = 256 x
## 0x00). Tiles are written starting at the bottom row, left to right, moving
## up. Floor and ceiling layers are additionally transposed and mirrored.
##
## OpenQBORG extensions (see docs/FORMAT.md), only written when used, so
## classic worlds round-trip byte for byte:
##   <gen><size> W H </size></gen>   world size, 16..256 per side (hex)
##   <map><js> ... </js></map>        script trigger ids per tile
##   <ext><js><file HREF="x.js"/></js></ext>  world scripts (scripts/ folder)
##
## Everything this player doesn't understand (tok, web, ent, lnk, lnk2, pal,
## unknown <ext> entries) is kept verbatim so open -> save is lossless.

const CLASSIC_SIZE := 16
const MAX_SIZE := 256
## Floor/ceiling value meaning "no tile here".
const EMPTY_SURFACE := 255
## Pixels per tile edge in CYBERWORLD world units.
const TILE_PX := 256.0
## Start position units per tile (classic <pos> x/y are 0..1024).
const POS_PER_TILE := 64.0

## Layers whose file order is transposed + mirrored relative to the others.
const SURFACE_LAYERS := ["flr", "cei"]
## Layer order CYBERWORLD's authoring tools write.
const DEFAULT_LAYER_ORDER := ["wal", "hgt", "flr", "cei", "obj", "gtw", "gtw2",
		"ent", "wav", "mid", "lnk", "lnk2"]

var version := "3.0"
var brg_attrs := {"VER": "3.0", "BS": "000000"}
var meta := {"Title": "untitled", "Description": "QBORG", "Date": "",
		"Type": "QBORG", "Rights": ""}
## Raw <gen> attributes (hex strings), e.g. HT, SP, TP, APP, MFG.
var gen_attrs := {"TP": "fffffffe", "SP": "96", "HT": "40", "APP": "3", "MFG": "cb"}
## Everything inside <gen> other than <pos> and <size>, as raw XML nodes.
var gen_extra: Array = []
## Start position, raw: [x, y (flipped), eye height, angle (0..4096)].
var start_pos := PackedInt32Array([512, 512, 16, 0])
var width := CLASSIC_SIZE
var height := CLASSIC_SIZE
var map_attrs := {"RL": "10"}
var layer_order: Array = DEFAULT_LAYER_ORDER.duplicate()
## layer name -> PackedByteArray(width * height), logical index = y * width + x.
var layers := {}
## <ext> entries in file order: {tag, attrs: Dictionary, items: Array of
## {kind: "file" | "cfil", href: String, text: String}}.
var ext: Array = []


static func create_empty(w := CLASSIC_SIZE, h := CLASSIC_SIZE) -> BorgLevel:
	var level := BorgLevel.new()
	level.width = clampi(w, CLASSIC_SIZE, MAX_SIZE)
	level.height = clampi(h, CLASSIC_SIZE, MAX_SIZE)
	for name in DEFAULT_LAYER_ORDER:
		level.layers[name] = level._blank_grid(name)
	level.set_start_tile_position(Vector2(level.width / 2.0, level.height / 2.0))
	level.meta["Date"] = Time.get_date_string_from_system()
	level.ext.append({"tag": "bdp", "attrs": {"BC": "0", "POS": "0"}, "items": []})
	return level


func is_classic_size() -> bool:
	return width == CLASSIC_SIZE and height == CLASSIC_SIZE


func tile_count() -> int:
	return width * height


func _blank_grid(layer: String) -> PackedByteArray:
	var grid := PackedByteArray()
	grid.resize(width * height)
	grid.fill(EMPTY_SURFACE if layer in SURFACE_LAYERS else 0)
	return grid


## Resizes the world, keeping existing tiles anchored at the top-left.
func resize(w: int, h: int) -> void:
	w = clampi(w, CLASSIC_SIZE, MAX_SIZE)
	h = clampi(h, CLASSIC_SIZE, MAX_SIZE)
	var old_w := width
	var old_h := height
	var start := start_tile_position()
	width = w
	height = h
	for name in layers:
		var old: PackedByteArray = layers[name]
		var grid := _blank_grid(name)
		for y in mini(old_h, h):
			for x in mini(old_w, w):
				grid[y * w + x] = old[y * old_w + x]
		layers[name] = grid
	set_start_tile_position(start.clamp(Vector2.ZERO, Vector2(w - 0.5, h - 0.5)))


# --- Grid access -------------------------------------------------------------

func in_bounds(x: int, y: int) -> bool:
	return x >= 0 and y >= 0 and x < width and y < height


func get_cell(layer: String, x: int, y: int) -> int:
	if not layers.has(layer) or not in_bounds(x, y):
		return 0
	return layers[layer][y * width + x]


func set_cell(layer: String, x: int, y: int, value: int) -> void:
	if not in_bounds(x, y):
		return
	if not layers.has(layer):
		layers[layer] = _blank_grid(layer)
		if not layer in layer_order:
			layer_order.append(layer)
	layers[layer][y * width + x] = clampi(value, 0, 255)


# --- <gen> helpers -----------------------------------------------------------

## Ceiling / full wall height in world pixels (HT is stored in quarter pixels).
func ceiling_height_px() -> float:
	return hex_to_int(gen_attrs.get("HT", "40")) * 4.0


func set_ceiling_height_px(px: float) -> void:
	gen_attrs["HT"] = "%x" % int(round(px / 4.0))


func speed() -> int:
	return hex_to_int(gen_attrs.get("SP", "96"))


func set_speed(value: int) -> void:
	gen_attrs["SP"] = "%x" % value


## Start position in tile units (x right, y down the grid).
func start_tile_position() -> Vector2:
	return Vector2(start_pos[0] / POS_PER_TILE, height - start_pos[1] / POS_PER_TILE)


func set_start_tile_position(p: Vector2) -> void:
	start_pos[0] = clampi(int(round(p.x * POS_PER_TILE)), 0, int(width * POS_PER_TILE))
	start_pos[1] = clampi(int(round((height - p.y) * POS_PER_TILE)), 0, int(height * POS_PER_TILE))


func start_eye_height_px() -> float:
	return start_pos[2] * 4.0


## Start yaw in radians, Godot convention (0 = looking down -Z / grid "up").
func start_yaw() -> float:
	return deg_to_rad(270.0 - start_pos[3] / 4096.0 * 360.0)


func set_start_yaw(yaw: float) -> void:
	var deg := fposmod(270.0 - rad_to_deg(yaw), 360.0)
	start_pos[3] = int(round(deg / 360.0 * 4096.0)) % 4096


# --- <ext> helpers -----------------------------------------------------------

func find_ext(tag: String) -> Dictionary:
	for entry in ext:
		if entry.tag == tag:
			return entry
	return {}


func ensure_ext(tag: String) -> Dictionary:
	var entry := find_ext(tag)
	if entry.is_empty():
		entry = {"tag": tag, "attrs": {}, "items": []}
		ext.append(entry)
	return entry


## HREFs of the <file> items under an <ext> tag (sprites, links, sounds...).
func ext_files(tag: String) -> PackedStringArray:
	var out := PackedStringArray()
	var entry := find_ext(tag)
	if entry.is_empty():
		return out
	for item in entry.items:
		if item.kind == "file":
			out.append(item.href)
	return out


func set_ext_files(tag: String, hrefs: PackedStringArray) -> void:
	if hrefs.is_empty() and find_ext(tag).is_empty():
		return
	var entry := ensure_ext(tag)
	entry.items = entry.items.filter(func(i): return i.kind != "file")
	for href in hrefs:
		entry.items.append({"kind": "file", "href": href, "text": ""})
	if entry.items.is_empty() and entry.attrs.is_empty():
		ext.erase(entry)


func ext_file(tag: String) -> String:
	var files := ext_files(tag)
	return files[0] if files.size() > 0 else ""


## Tiled texture reference: <cfil HREF="x.flr">0 10000 20000</cfil>.
## Offsets are pixel offsets into the image (y * width + x), in hex.
func ext_cfil(tag: String) -> Dictionary:
	var entry := find_ext(tag)
	if entry.is_empty():
		return {}
	for item in entry.items:
		if item.kind == "cfil":
			var offsets := PackedInt64Array()
			for token in item.text.strip_edges().split(" ", false):
				offsets.append(hex_to_int(token))
			return {"href": item.href, "offsets": offsets}
	return {}


func set_ext_cfil(tag: String, href: String, offsets: PackedInt64Array) -> void:
	if href.is_empty():
		var existing := find_ext(tag)
		if not existing.is_empty():
			ext.erase(existing)
		return
	var entry := ensure_ext(tag)
	var parts := PackedStringArray()
	for o in offsets:
		parts.append("%x" % o)
	entry.items = [{"kind": "cfil", "href": href, "text": " ".join(parts) + " "}]


## Background colour. CYBERWORLD stores it as BGR hex.
func background_color() -> Color:
	var bc: String = find_ext("bdp").get("attrs", {}).get("BC", "0")
	bc = bc.lpad(6, "0")
	return Color8(bc.substr(4, 2).hex_to_int(), bc.substr(2, 2).hex_to_int(),
			bc.substr(0, 2).hex_to_int())


func set_background_color(c: Color) -> void:
	ensure_ext("bdp").attrs["BC"] = "%02x%02x%02x" % [c.b8, c.g8, c.r8]


## Vertical backdrop offset in pixels (signed 32-bit hex in the file).
func backdrop_offset() -> int:
	return hex_to_signed(find_ext("bdp").get("attrs", {}).get("POS", "0"))


func set_backdrop_offset(px: int) -> void:
	ensure_ext("bdp").attrs["POS"] = "%x" % (px & 0xffffffff)


# --- Parsing -----------------------------------------------------------------

static func parse(text: String) -> BorgLevel:
	var root := BorgXml.parse(text)
	if root.is_empty() or root.name != "brg":
		push_error("Not a .borg document")
		return null
	var level := BorgLevel.new()
	level.brg_attrs = root.attrs.duplicate()
	level.version = root.attrs.get("VER", "3.0")
	level.layers.clear()
	level.layer_order.clear()
	level.ext.clear()

	for child in root.children:
		match child.name:
			"rdf:RDF":
				for desc in child.children:
					for field in desc.children:
						level.meta[field.name.trim_prefix("dc:")] = field.text.strip_edges()
			"gen":
				level.gen_attrs = child.attrs.duplicate()
				level.gen_extra.clear()
				for g in child.children:
					if g.name == "pos":
						var nums := _hex_list(g.text)
						while nums.size() < 4:
							nums.append(0)
						level.start_pos = nums
					elif g.name == "size":
						var dims := _hex_list(g.text)
						if dims.size() >= 1:
							level.width = clampi(dims[0], CLASSIC_SIZE, MAX_SIZE)
							level.height = clampi(dims[1] if dims.size() > 1 else dims[0], CLASSIC_SIZE, MAX_SIZE)
					else:
						level.gen_extra.append(g)
			"map":
				level.map_attrs = child.attrs.duplicate()
				for layer in child.children:
					level.layer_order.append(layer.name)
					level.layers[layer.name] = decode_layer(layer.text, layer.name in SURFACE_LAYERS,
							level.width, level.height)
			"ext":
				for entry in child.children:
					var items := []
					for item in entry.children:
						items.append({"kind": item.name, "href": item.attrs.get("HREF", ""),
								"text": item.text})
					level.ext.append({"tag": entry.name, "attrs": entry.attrs.duplicate(),
							"items": items})
	return level


static func load_file(path: String) -> BorgLevel:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return null
	return parse(f.get_as_text())


static func _hex_list(text: String) -> PackedInt32Array:
	var nums := PackedInt32Array()
	for t in text.strip_edges().split(" ", false):
		nums.append(hex_to_int(t))
	return nums


## Decodes an RLE layer into logical y * w + x order.
static func decode_layer(text: String, surface: bool, w := CLASSIC_SIZE, h := CLASSIC_SIZE) -> PackedByteArray:
	var total := w * h
	var grid := PackedByteArray()
	grid.resize(total)
	grid.fill(EMPTY_SURFACE if surface else 0)
	var i := 0
	for token in text.strip_edges().split(" ", false):
		if token.length() < 2:
			continue
		var value := token.right(2).hex_to_int()
		var count := 1 if token.length() == 2 else token.left(token.length() - 2).hex_to_int()
		for n in count:
			if i >= total:
				break
			grid[_stream_to_logical(i, surface, w, h)] = value
			i += 1
	return grid


static func encode_layer(grid: PackedByteArray, surface: bool, w := CLASSIC_SIZE, h := CLASSIC_SIZE) -> String:
	var tokens := PackedStringArray()
	var run_value := -1
	var run_count := 0
	for i in w * h:
		var v: int = grid[_stream_to_logical(i, surface, w, h)]
		if v == run_value:
			run_count += 1
		else:
			if run_count > 0:
				tokens.append("%x%02x" % [run_count, run_value])
			run_value = v
			run_count = 1
	tokens.append("%x%02x" % [run_count, run_value])
	return " ".join(tokens)


## Stream position i -> logical grid index. Normal layers stream rows of w
## tiles from the bottom row up. Surface layers are stored transposed and
## mirrored: rows of h tiles, one per grid column, walking each column upward.
static func _stream_to_logical(i: int, surface: bool, w: int, h: int) -> int:
	if surface:
		var x := i / h
		var y := h - 1 - i % h
		return y * w + x
	return (h - 1 - i / w) * w + i % w


# --- Writing -----------------------------------------------------------------

func serialize() -> String:
	var nl := "\r\n"
	var s := PackedStringArray()
	s.append('<?xml version="1.0"?>')
	s.append("<brg%s>" % _attr_string(brg_attrs))
	s.append('\t<rdf:RDF xmlns:rdf="http://w3.org/TR/1999/PR-rdf-syntax-19990105#"')
	s.append('\t         xmlns:dc="http://purl.org/metadata/dublin_core#">')
	s.append("\t<rdf:Description>")
	for key in meta:
		s.append("\t\t<dc:%s> %s </dc:%s>" % [key, BorgXml.escape(str(meta[key])), key])
	s.append("\t</rdf:Description>")
	s.append("\t</rdf:RDF>")
	s.append("")
	s.append("<gen%s>" % _attr_string(gen_attrs))
	var pos_line := "\t<pos> %x %x %x %x </pos>" % [start_pos[0], start_pos[1], start_pos[2], start_pos[3]]
	var pos_emitted := false
	for g in gen_extra:
		s.append("\t" + BorgXml.write_node(g))
		# Keep <pos> in its usual slot, right after <tok>.
		if g.name == "tok":
			s.append(pos_line)
			pos_emitted = true
	if not pos_emitted:
		s.append(pos_line)
	if not is_classic_size():
		s.append("\t<size> %x %x </size>" % [width, height])
	s.append("</gen>")
	s.append("<map%s>" % _attr_string(map_attrs))
	for name in layer_order:
		if layers.has(name):
			s.append("\t<%s> %s </%s>" % [name,
					encode_layer(layers[name], name in SURFACE_LAYERS, width, height), name])
	s.append("</map>")
	s.append("<ext>")
	for entry in ext:
		if entry.items.is_empty():
			s.append("<%s%s/>" % [entry.tag, _attr_string(entry.attrs)])
			continue
		s.append("<%s%s>" % [entry.tag, _attr_string(entry.attrs)])
		for item in entry.items:
			var indent := "" if entry.tag == "bdp" else "\t"
			if item.text.strip_edges().is_empty():
				s.append('%s<%s HREF="%s"/>' % [indent, item.kind, BorgXml.escape(item.href)])
			else:
				s.append('%s<%s HREF="%s">%s</%s>' % [indent, item.kind,
						BorgXml.escape(item.href), BorgXml.escape(item.text), item.kind])
		s.append("</%s>" % entry.tag)
	s.append("</ext>")
	s.append("</brg>")
	return nl.join(s) + nl


func save_file(path: String) -> Error:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	f.store_string(serialize())
	return OK


static func _attr_string(attrs: Dictionary) -> String:
	var out := ""
	for key in attrs:
		out += ' %s="%s"' % [key, BorgXml.escape(str(attrs[key]))]
	return out


static func hex_to_int(s: String) -> int:
	s = s.strip_edges()
	return 0 if s.is_empty() else s.hex_to_int()


static func hex_to_signed(s: String) -> int:
	var v := hex_to_int(s) & 0xffffffff
	return v - 0x100000000 if v >= 0x80000000 else v
