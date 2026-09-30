# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 Mark Toman and OpenQBORG contributors
extends SceneTree
## Headless checks for the shared core. From the repo root:
##   godot --headless --path player --script res://addons/openqborg_core/tests/run_tests.gd -- [world_dir] [--audio=dir] [--frames=dir]
## Without a world dir only the synthetic tests run. With one, every .borg is
## parsed and round-tripped and every .sprite is decoded.

var failures := 0


func _init() -> void:
	_test_rle()
	_test_urls()
	_test_empty_roundtrip()
	_test_sprite_roundtrip()
	_test_sprite_behaviour()
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--audio="):
			_test_audio_dir(arg.trim_prefix("--audio="))
		elif arg.begins_with("--frames="):
			_test_frames_dir(arg.trim_prefix("--frames="))
		else:
			_test_world_dir(arg)
	print("FAILED: %d" % failures if failures else "ALL PASSED")
	quit(1 if failures else 0)


func check(cond: bool, what: String) -> void:
	if not cond:
		failures += 1
		printerr("FAIL: " + what)


func _test_rle() -> void:
	var text := "2201 200 e01 400 d01 400 f01 200 e01 200 d01 300 8801"
	for surface in [false, true]:
		var grid := BorgLevel.decode_layer(text, surface)
		check(BorgLevel.encode_layer(grid, surface) == text, "RLE round trip surface=%s" % surface)
	var g := BorgLevel.decode_layer("10000", false)
	check(g.count(0) == 256, "RLE fill")
	# First stream tile is bottom-left for normal layers...
	g = BorgLevel.decode_layer("101 ff00", false)
	check(g[15 * 16 + 0] == 1, "stream starts at bottom row")
	# ...and the mirrored/transposed corner for floors and ceilings.
	g = BorgLevel.decode_layer("101 ff00", true)
	check(g[15 * 16 + 0] == 1, "surface stream origin")
	# Stepping along a stream row walks *up* a column for surfaces.
	g = BorgLevel.decode_layer("100 101 fe00", true)
	check(g[14 * 16 + 0] == 1, "surface stream is transposed")


func _test_urls() -> void:
	check(BorgUrl.to_fetchable("borg://example.com/w/a.borg") == "http://example.com/w/a.borg", "borg -> http")
	check(BorgUrl.to_fetchable("borgs://example.com/w/a.borg") == "https://example.com/w/a.borg", "borgs -> https")
	check(BorgUrl.to_fetchable("borg://example.com/w/a.borg", "https://example.com/w/b.borg") \
			== "https://example.com/w/a.borg", "no TLS downgrade from page links")
	check(BorgUrl.to_display("https://h/a.borg") == "borgs://h/a.borg", "display borgs")
	check(BorgUrl.join("http://h/w/borgs/domains/", "../html/x.html") == "http://h/w/borgs/html/x.html", "join ..")
	check(BorgUrl.resolve_shortcut_target("http://../html/i/x.html", "http://h/b/domains/") \
			== "http://h/b/html/i/x.html", "relative shortcut")
	check(BorgUrl.resolve_shortcut_target("http://www.cwarp.com/", "http://h/b/domains/") \
			== "http://www.cwarp.com/", "absolute shortcut")
	var c := BorgUrl.classify("borg://cmd.web@http://h/p/page.html")
	check(c.kind == BorgUrl.Kind.COMMAND_WEB and c.url == "http://h/p/page.html", "cmd.web")
	check(BorgUrl.classify("borg://cmd.prev").kind == BorgUrl.Kind.COMMAND_PREV, "cmd.prev")
	var wb := "https://web.archive.org/web/2001id_/http://www2.warnerbros.com:80/zeta/borgs/"
	check(BorgUrl.join(wb, "domains/../media/zeta.mid") == wb + "media/zeta.mid", "Wayback addresses keep their embedded http://")
	check(BorgUrl.to_fetchable("borgs://h/a b %2B c/w.borg") == "https://h/a%20b%20%2B%20c/w.borg", "spaces from the command line are re-encoded")
	check(BorgUrl.to_fetchable("borgs://web.archive.org/web/2001id_/http://h/a.borg") \
			== "https://web.archive.org/web/2001id_/http://h/a.borg", "Wayback borgs:// -> https")


func _test_empty_roundtrip() -> void:
	var level := BorgLevel.create_empty()
	level.set_cell("flr", 3, 4, 2)
	level.set_cell("obj", 5, 6, 1)
	level.set_start_tile_position(Vector2(2.5, 7.25))
	level.set_start_yaw(1.0)
	level.set_background_color(Color8(10, 20, 30))
	level.set_backdrop_offset(-2)
	var again := BorgLevel.parse(level.serialize())
	check(again != null, "empty level parses")
	if again == null:
		return
	check(again.get_cell("flr", 3, 4) == 2 and again.get_cell("flr", 0, 0) == 255, "floor survives")
	check(again.get_cell("obj", 5, 6) == 1, "object survives")
	check(again.start_tile_position().distance_to(Vector2(2.5, 7.25)) < 0.02, "start pos")
	check(absf(angle_difference(again.start_yaw(), 1.0)) < 0.01, "start yaw")
	check(again.background_color().is_equal_approx(Color8(10, 20, 30)), "BGR colour")
	check(again.backdrop_offset() == -2, "signed POS")
	check(not level.serialize().contains("<size>"), "classic worlds never write <size>")
	_test_sized_world()


func _test_world_dir(dir_path: String) -> void:
	var borgs := _find(dir_path, ".borg")
	check(borgs.size() > 0, "found .borg files in " + dir_path)
	for path in borgs:
		var level := BorgLevel.load_file(path)
		check(level != null, "parse " + path)
		if level == null:
			continue
		var original := FileAccess.get_file_as_string(path)
		var again := BorgLevel.parse(level.serialize())
		for name in level.layers:
			check(again.layers.get(name) == level.layers[name], "%s layer %s round trip" % [path.get_file(), name])
			# Byte-exact layer text, so the original tools still read our saves.
			var enc := BorgLevel.encode_layer(level.layers[name], name in BorgLevel.SURFACE_LAYERS, level.width, level.height)
			check(original.contains("<%s> %s </%s>" % [name, enc, name]),
					"%s %s encodes identically" % [path.get_file(), name])
		check(again.ext.size() == level.ext.size(), path.get_file() + " ext entries survive")
		check(again.start_pos == level.start_pos, path.get_file() + " pos survives")
		print("ok  %-28s sprites=%d start=%s" % [path.get_file(), level.ext_files("spr").size(),
				level.start_tile_position()])
	var sprites := _find(dir_path, ".sprite")
	var decoded := 0
	var cws3 := 0
	var interactive := 0
	for path in sprites:
		var s := CWSprite.decode(FileAccess.get_file_as_bytes(path), path)
		check(s != null and s.image != null, "decode sprite " + path)
		if s != null:
			decoded += 1
			cws3 += 1 if s.version >= 3 else 0
			interactive += 1 if s.is_interactive() else 0
	print("sprites decoded: %d/%d (CWS3: %d, interactive: %d)" % [decoded, sprites.size(), cws3, interactive])


func _find(dir_path: String, ext: String) -> PackedStringArray:
	var out := PackedStringArray()
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return out
	for f in dir.get_files():
		if f.to_lower().ends_with(ext):
			out.append(dir_path.path_join(f))
	for d in dir.get_directories():
		out.append_array(_find(dir_path.path_join(d), ext))
	return out


## OpenQBORG <size> extension: non-square, bigger than classic.
func _test_sized_world() -> void:
	var level := BorgLevel.create_empty(40, 24)
	level.set_cell("flr", 39, 0, 3)
	level.set_cell("flr", 0, 23, 4)
	level.set_cell("obj", 39, 23, 7)
	level.set_cell("js", 12, 20, 2)
	level.set_start_tile_position(Vector2(30.5, 20.25))
	var text := level.serialize()
	check(text.contains("<size> 28 18 </size>"), "size element written")
	var again := BorgLevel.parse(text)
	check(again.width == 40 and again.height == 24, "size parsed")
	check(again.get_cell("flr", 39, 0) == 3 and again.get_cell("flr", 0, 23) == 4, "sized floor corners")
	check(again.get_cell("obj", 39, 23) == 7, "sized object corner")
	check(again.get_cell("js", 12, 20) == 2, "js trigger layer")
	level.set_surfaces([{"id": "screen", "url": "https://example.org/v", "kind": "wall", "face": "s",
			"x": 3, "y": 0, "len": 8, "w": 1, "d": 1, "z": 16, "h": 400}])
	var with_srf := BorgLevel.parse(level.serialize())
	var srf := with_srf.surfaces()
	check(srf.size() == 1 and srf[0].len == 8 and srf[0].face == "s" and srf[0].h == 400 and srf[0].url == "https://example.org/v",
			"web surface survives a round trip")
	check(again.start_tile_position().distance_to(Vector2(30.5, 20.25)) < 0.02, "sized start pos")
	for name in level.layers:
		check(again.layers[name] == level.layers[name], "sized layer %s round trip" % name)
	var big := BorgLevel.create_empty(300, 8)
	check(big.width == 256 and big.height == 16, "size clamps to 16..256")
	again.resize(16, 16)
	check(again.is_classic_size() and not again.serialize().contains("<size>"), "shrink back to classic")


## Every audio file in `dir` must decode (MIDI is skipped: BorgMusic plays it).
func _test_audio_dir(dir_path: String) -> void:
	print("FFmpeg extension: %s" % (ClassDB.class_call_static("FFmpegAudioDecoder", "ffmpeg_version")
			if BorgAudio.has_ffmpeg() else "not loaded"))
	var dir := DirAccess.open(dir_path)
	check(dir != null, "audio dir " + dir_path)
	if dir == null:
		return
	for f in dir.get_files():
		var bytes := FileAccess.get_file_as_bytes(dir_path.path_join(f))
		if BorgAudio.is_midi(bytes):
			continue
		var stream := BorgAudio.decode(bytes, f)
		var ok := stream != null and stream.get_length() > 0.1
		check(ok, "decode %s (%s)" % [f, BorgAudio.last_error])
		if stream != null:
			BorgAudio.set_looping(stream)
			print("%-14s %-8s -> %-22s %.2fs" % [f, BorgAudio.sniff(bytes), stream.get_class(), stream.get_length()])


func _test_sprite_roundtrip() -> void:
	var s := CWSprite.new()
	s.image = Image.create(32, 96, false, Image.FORMAT_RGBA8)
	s.image.fill(Color.MAGENTA)
	s.image.fill_rect(Rect2i(8, 40, 16, 16), Color.YELLOW)
	s.cell_count = 3
	s.cell_width = 32
	s.cell_height = 32
	s.world_x = 100
	s.world_z = 12
	s.world_width = 64
	s.world_height = 64
	s.animate_on_load = true
	s.frame_count = 3
	s.frame_durations = PackedInt32Array([100, 200, 300])
	s.on_south = true
	var back := CWSprite.decode(s.to_png_bytes(), "t.sprite")
	check(back != null and back.has_metadata, "encoded sprite decodes with metadata")
	if back == null:
		return
	check(back.cell_count == 3 and back.cell_height == 32 and back.world_x == 100 and back.world_z == 12,
			"sprite geometry survives")
	check(back.animate_on_load and back.frame_durations == PackedInt32Array([100, 200, 300]), "sprite animation survives")
	check(back.on_south and not back.on_north, "sprite wall flags survive")
	check(back.image.get_pixel(0, 0).a == 0.0 and back.image.get_pixel(12, 44).a == 1.0, "colour key applied")


## Pictures in `dir` named anim.* must decode to several frames with delays,
## still.* to exactly one (see the ffmpeg testsrc commands in the docs).
func _test_frames_dir(dir_path: String) -> void:
	print("frame decoder: %s" % ("loaded" if BorgFrames.has_decoder() else "not loaded"))
	for f in DirAccess.get_files_at(dir_path):
		var bytes := FileAccess.get_file_as_bytes(dir_path.path_join(f))
		var frames := BorgFrames.decode(bytes)
		var kind := BorgFrames.sniff(bytes)
		if f.begins_with("anim."):
			check(frames != null and frames.images.size() >= 4 and frames.total_ms > 0,
					"animated %s decodes to frames" % f)
		else:
			check(frames != null and frames.images.size() == 1, "still %s decodes to one frame" % f)
		if frames != null:
			var img := frames.first()
			check(img.get_size() == Vector2i(256, 512), "%s frame size" % f)
			print("%-14s %-6s -> %2d frame(s), %4d ms loop, %s" % [f, kind, frames.images.size(),
					frames.total_ms, img.get_size()])
	# Animated files double as sprites.
	for f in ["anim.gif", "anim.apng", "anim.mjpeg"]:
		var s := CWSprite.decode(FileAccess.get_file_as_bytes(dir_path.path_join(f)), f)
		check(s != null and s.cell_count == 6 and s.animate_on_load and s.cell_height == 512,
				"%s decodes as a 6-frame animated sprite" % f)
	# Plain JPEGs must not be mistaken for Motion JPEG.
	check(BorgFrames.sniff(FileAccess.get_file_as_bytes(dir_path.path_join("still.jpg"))) == "image",
			"single JPEG is not MJPEG")


## CWS3 behaviours: a 4-frame sprite with every group used.
func _test_sprite_behaviour() -> void:
	var s := CWSprite.new()
	s.image = Image.create(8, 32, false, Image.FORMAT_RGBA8)
	s.image.fill(Color.MAGENTA)
	s.cell_count = 4
	s.cell_width = 8
	s.cell_height = 8
	s.frame_count = 4
	s.frame_durations = PackedInt32Array([100, 100, 100, 100])
	s.animate_on_load = false
	s.proximity_distance = 300
	s.groups = s.default_groups()
	s.groups[CWSprite.Group.MOUSE_OVER] = {"enabled": true, "from": 1, "to": 1, "repeat": 0, "end": -1,
			"revert": CWSprite.REVERT_ON_EXIT}
	s.groups[CWSprite.Group.CLICK] = {"enabled": true, "from": 0, "to": 2, "repeat": 1, "end": 2, "revert": 0}
	s.groups[CWSprite.Group.PROXIMITY] = {"enabled": true, "from": 3, "to": 0, "repeat": 2, "end": -1, "revert": 0}
	var back := CWSprite.decode(s.to_png_bytes(), "b.sprite")
	check(back != null and back.version == 3, "CWS3 written and read back")
	if back == null:
		return
	check(back.proximity_distance == 300 and back.groups[2].end == 2 and back.groups[3].from == 3,
			"CWS3 groups survive")
	check(back.is_interactive(), "sprite with behaviours is interactive")

	var node := Sprite3D.new()
	node.texture = ImageTexture.create_from_image(back.image)
	node.vframes = 4
	var b := SpriteBehaviour.new(node, back, Vector2i(3, 3))
	check(node.frame == 0, "general: static frame 0 (not animated on load)")
	b.set_hovered(true)
	check(b.group == CWSprite.Group.MOUSE_OVER and node.frame == 1, "mouse-over shows frame 1")
	b.set_hovered(false)
	check(b.group == CWSprite.Group.GENERAL and node.frame == 0, "leaving reverts (revert on exit)")
	b.click()
	b.tick(150)
	check(node.frame == 1, "click plays forward")
	b.tick(300)
	check(b.group == CWSprite.Group.CLICK and node.frame == 2, "click plays once and holds its end frame")
	b.set_near(true)
	check(b.group == CWSprite.Group.PROXIMITY and node.frame == 3, "proximity starts at its from frame")
	b.tick(350)
	check(node.frame == 0, "proximity plays backwards (from > to)")
	b.tick(450)
	check(b.group == CWSprite.Group.GENERAL, "after its repeats, end -1 returns to general")
	node.free()
