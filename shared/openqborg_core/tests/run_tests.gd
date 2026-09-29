extends SceneTree
## Headless checks for the shared core. From the repo root:
##   godot --headless --path player --script res://addons/openqborg_core/tests/run_tests.gd -- [world_dir]
## Without a world dir only the synthetic tests run. With one, every .borg is
## parsed and round-tripped and every .sprite is decoded.

var failures := 0


func _init() -> void:
	_test_rle()
	_test_urls()
	_test_empty_roundtrip()
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		_test_world_dir(args[0])
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
			var enc := BorgLevel.encode_layer(level.layers[name], name in BorgLevel.SURFACE_LAYERS)
			check(original.contains("<%s> %s </%s>" % [name, enc, name]),
					"%s %s encodes identically" % [path.get_file(), name])
		check(again.ext.size() == level.ext.size(), path.get_file() + " ext entries survive")
		check(again.start_pos == level.start_pos, path.get_file() + " pos survives")
		print("ok  %-28s sprites=%d start=%s" % [path.get_file(), level.ext_files("spr").size(),
				level.start_tile_position()])
	var sprites := _find(dir_path, ".sprite")
	var decoded := 0
	for path in sprites:
		var s := CWSprite.decode(FileAccess.get_file_as_bytes(path), path)
		check(s != null and s.image != null, "decode sprite " + path)
		if s != null:
			decoded += 1
	print("sprites decoded: %d/%d" % [decoded, sprites.size()])


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
	check(again.start_tile_position().distance_to(Vector2(30.5, 20.25)) < 0.02, "sized start pos")
	for name in level.layers:
		check(again.layers[name] == level.layers[name], "sized layer %s round trip" % name)
	var big := BorgLevel.create_empty(300, 8)
	check(big.width == 256 and big.height == 16, "size clamps to 16..256")
	again.resize(16, 16)
	check(again.is_classic_size() and not again.serialize().contains("<size>"), "shrink back to classic")
