# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 Mark Toman and OpenQBORG contributors
class_name CWSprite
extends RefCounted
## CYBERWORLD sprite (.sprite / .ctrl).
##
## A .sprite is an ordinary PNG or JPEG whose frames are stacked vertically,
## with placement/animation metadata in a private block:
##   PNG:  a "cxBX" chunk starting with the marker "CWS2" or "CWS3"
##   JPEG: an APPn segment starting with "CWS2" / "CWS3"
## All metadata fields are little-endian uint32. The top-left pixel is the
## transparent colour key. A .ctrl is a text property list (VT_* typed) for
## ActiveX control placeholders.

var image: Image
var cell_count := 1
var cell_width := 32
var cell_height := 32
## Offset within the tile in world pixels (128 = tile centre).
var world_x := 128
var world_y := 128
## Height of the sprite's bottom edge above the floor, world pixels.
var world_z := 10
var world_width := 256
var world_height := 256
var multi_sided := false
var sides := 1
var animate_on_load := false
var frame_count := 1
var default_duration := 66
var frame_durations := PackedInt32Array([66])
var repeat_count := 0
var menu_item := true
## When the tile has a wall, the sprite is painted onto these faces instead.
var on_north := false
var on_south := false
var on_west := false
var on_east := false
## False when the file had no CWS block (plain image): use its own size.
var has_metadata := false


static func decode(bytes: PackedByteArray, name: String) -> CWSprite:
	var s := CWSprite.new()
	if name.to_lower().ends_with(".ctrl"):
		s._parse_ctrl(bytes.get_string_from_utf8())
		s.image = Image.create(max(1, s.cell_width), max(1, s.cell_height), false, Image.FORMAT_RGBA8)
		s.image.fill(Color.WHITE)
		return s
	if bytes.size() < 4:
		return null
	var is_png := bytes[0] == 0x89 and bytes[1] == 0x50 and bytes[2] == 0x4e and bytes[3] == 0x47
	var is_jpeg := bytes[0] == 0xff and bytes[1] == 0xd8
	var img := Image.new()
	if is_png:
		s._scan_png(bytes)
		if img.load_png_from_buffer(bytes) != OK:
			return null
	elif is_jpeg:
		s._scan_jpeg(bytes)
		if img.load_jpg_from_buffer(bytes) != OK:
			return null
	else:
		return null
	img.convert(Image.FORMAT_RGBA8)
	if not s.has_metadata:
		s.cell_width = img.get_width()
		s.cell_height = img.get_height()
		s.cell_count = 1
		s.world_width = img.get_width()
		s.world_height = img.get_height()
	# The declared cell block can be smaller than the image; crop to it.
	var w := mini(img.get_width(), s.cell_width) if s.cell_width > 0 else img.get_width()
	var h := mini(img.get_height(), s.cell_height * s.cell_count) if s.cell_height > 0 else img.get_height()
	if w != img.get_width() or h != img.get_height():
		img = img.get_region(Rect2i(0, 0, w, h))
	# JPEG compression smears the key colour, so allow a little slack there.
	_apply_color_key(img, 0 if is_png else 24)
	s.image = img
	s.cell_count = maxi(1, s.cell_count)
	s.frame_count = clampi(s.frame_count, 1, s.cell_count)
	return s


static func _apply_color_key(img: Image, tolerance: int) -> void:
	var key := img.get_pixel(0, 0)
	var data := img.get_data()
	var kr := key.r8
	var kg := key.g8
	var kb := key.b8
	for i in range(0, data.size(), 4):
		if absi(data[i] - kr) <= tolerance and absi(data[i + 1] - kg) <= tolerance \
				and absi(data[i + 2] - kb) <= tolerance:
			data[i + 3] = 0
	img.set_data(img.get_width(), img.get_height(), false, Image.FORMAT_RGBA8, data)


func _scan_png(bytes: PackedByteArray) -> void:
	var offset := 8
	while offset + 8 <= bytes.size():
		var length := (bytes[offset] << 24) | (bytes[offset + 1] << 16) | (bytes[offset + 2] << 8) | bytes[offset + 3]
		var code := bytes.slice(offset + 4, offset + 8).get_string_from_ascii()
		var body := offset + 8
		if code == "cxBX" and length >= 4:
			var marker := bytes.slice(body, body + 4).get_string_from_ascii()
			_parse_cws(bytes.slice(body + 4, body + length), marker)
		if code == "IEND":
			break
		offset = body + length + 4 # skip CRC


func _scan_jpeg(bytes: PackedByteArray) -> void:
	var offset := 2
	while offset + 4 <= bytes.size():
		if bytes[offset] != 0xff:
			return
		var marker := bytes[offset + 1]
		if marker == 0xd9 or marker == 0xda: # EOI / start of scan: no more APPn
			return
		var length := (bytes[offset + 2] << 8) | bytes[offset + 3]
		var body := offset + 4
		if marker >= 0xe0 and marker <= 0xef and length >= 6:
			var tag := bytes.slice(body, body + 4).get_string_from_ascii()
			if tag == "CWS2" or tag == "CWS3":
				_parse_cws(bytes.slice(body + 4, body + length - 2), tag)
		offset += 2 + length


func _parse_cws(chunk: PackedByteArray, _marker: String) -> void:
	if chunk.size() < 64:
		return
	has_metadata = true
	var o := 0
	cell_count = chunk.decode_u32(o); o += 4
	cell_width = chunk.decode_u32(o); o += 4
	cell_height = chunk.decode_u32(o); o += 4
	world_z = chunk.decode_u32(o); o += 4
	world_y = chunk.decode_u32(o); o += 4
	world_x = chunk.decode_u32(o); o += 4
	var flags := chunk.decode_u32(o); o += 4
	multi_sided = (flags >> 2) & 1 == 1
	menu_item = (flags >> 1) & 1 == 0
	animate_on_load = chunk.decode_u32(o) == 1; o += 4
	sides = maxi(1, chunk.decode_u32(o)); o += 4
	world_width = chunk.decode_u32(o); o += 4
	world_height = chunk.decode_u32(o); o += 4
	repeat_count = chunk.decode_u32(o); o += 4
	frame_count = chunk.decode_u32(o); o += 4
	default_duration = chunk.decode_u32(o); o += 4
	var vis := chunk.decode_u32(o); o += 4
	on_north = (vis >> 3) & 1 == 1
	on_south = (vis >> 2) & 1 == 1
	on_west = (vis >> 1) & 1 == 1
	on_east = vis & 1 == 1
	o += 4 # unknown
	frame_durations = PackedInt32Array()
	for f in frame_count:
		if o + 4 > chunk.size():
			break
		frame_durations.append(chunk.decode_u32(o)); o += 4
	while frame_durations.size() < maxi(1, frame_count):
		frame_durations.append(maxi(1, default_duration))
	# CWS3 adds mouse-over / click / proximity animation ranges after this.
	# TODO: parse and play those once a sample using them turns up.


func _parse_ctrl(text: String) -> void:
	var props := {}
	for line in text.split("\n"):
		line = line.strip_edges()
		if line.is_empty():
			continue
		var parts := line.split("\t")
		if parts.size() < 3:
			var sp := line.split(" ", false, 2)
			if sp.size() < 3:
				continue
			parts = sp
		match parts[1]:
			"VT_BOOL":
				props[parts[0]] = parts[2] == "TRUE"
			"VT_UI4", "VT_I4", "VT_R8":
				props[parts[0]] = int(parts[2])
			_:
				props[parts[0]] = parts[2]
	cell_width = props.get("CW_WIDTH", cell_width)
	cell_height = props.get("CW_HEIGHT", cell_height)
	world_width = props.get("CW_WORLDWIDTH", props.get("CW_WIDTH", world_width))
	world_height = props.get("CW_WORLDHEIGHT", props.get("CW_HEIGHT", world_height))
	world_x = 128 + int(props.get("CW_XPOSINTILE", 0))
	world_y = 128 + int(props.get("CW_YPOSINTILE", 0))
	world_z = int(props.get("CW_HEIGHTABOVEGROUND", 0))
	on_north = props.get("CW_NORTHWALL", false)
	on_south = props.get("CW_SOUTHWALL", false)
	on_west = props.get("CW_WESTWALL", false)
	on_east = props.get("CW_EASTWALL", false)
