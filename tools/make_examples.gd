# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 Mark Toman and OpenQBORG contributors
extends SceneTree
## Generates the editor's starter library (editor/library/) and the example
## worlds (examples/borgs/). Every texture, sprite, sound, tune and page is
## made here from code, so all of it is original and reproducible:
##
##   godot --headless --path player --script ../tools/make_examples.gd
##
## Optional: ffmpeg (Ogg/Opus/FLAC/AAC copies of the synthesized audio;
## otherwise WAV is used) and ImageMagick's `magick` (emblem lettering).

const TILE := 256
const KEY := Color(1, 0, 1) # sprite colour key
const RATE := 22050

## Floor/ceiling tiles in starter.flr, by index.
enum Floor { GRASS, PATH, WATER, STONE, PLATE, PAD, SAND, PLANKS, SNOW, DIRT, LAVA }
const FLOOR_NAMES := ["Grass", "Cobblestone path", "Water", "Stone floor", "Metal plate",
		"Glowing pad", "Sand", "Wooden planks", "Snow", "Dirt", "Lava"]
## Wall strips in starter.wal; a wall tile's `wal` value is strip + 1.
enum Wall { BRICK = 1, HEDGE, STONE, GATE, WOOD, MARBLE, WATERFALL }
const WALL_NAMES := ["Brick", "Hedge", "Stone blocks", "Iron gate", "Wooden planks", "Marble", "Waterfall"]
## Ceiling tiles in starter.cei, by index.
enum Ceiling { BEAMS, PLASTER, VAULT, CAVE, STARS, STAINED_GLASS, ORNATE }
const CEILING_NAMES := ["Wooden beams", "Plaster", "Stone vault", "Cave rock", "Starry night",
		"Stained glass", "Ornate tiles"]
## Frames and frame time of the animated texture sets.
const ANIM_FRAMES := 8
const ANIM_MS := 125

## Where _write() puts files: the library first, then the examples.
var out := ""
var lib := ""
var examples := ""
## library.json, filled in as assets are made.
var manifest := {"version": 1, "sprites": [], "sounds": [], "music": []}
var have_ffmpeg := false
var have_magick := false
var rng := RandomNumberGenerator.new()
var audio_names := {}


func _init() -> void:
	var root := ProjectSettings.globalize_path("res://").path_join("..").simplify_path()
	lib = root.path_join("editor/library")
	examples = root.path_join("examples/borgs")
	for base in [lib, examples]:
		for d in ["domains", "objects", "media", "scripts", "html"]:
			DirAccess.make_dir_recursive_absolute(base.path_join(d))
	have_ffmpeg = _has("ffmpeg")
	have_magick = _has("magick")
	rng.seed = 2026

	# 1. The starter library: generic assets any world can use.
	out = lib
	_make_textures()
	_make_sprites()
	_make_audio()
	_make_library_pages()
	_write_manifest()
	# Godot must not import the library as project resources.
	_write_text(".gdignore", "")

	# 2. The example worlds: the library assets plus their own maps, emblems
	# and pages, so each example folder is self-contained.
	out = examples
	for d in ["domains", "objects", "media"]:
		_copy_dir(lib.path_join(d), examples.path_join(d))
	for f in ["style.css", "qborg.js"]:
		DirAccess.copy_absolute(lib.path_join("html").path_join(f), examples.path_join("html").path_join(f))
	_make_emblem("hello.emb", "HELLO QBORG", Color("#1d4f8c"), Color("#3fa9f5"))
	_make_emblem("sprawl.emb", "THE SPRAWL", Color("#8c5a1d"), Color("#f5c03f"))
	_make_emblem("puzzle.emb", "ORB VAULT", Color("#3b1d8c"), Color("#a63ff5"))
	_make_pages()
	_make_hello()
	_make_sprawl()
	_make_puzzle()
	print("Starter library written to ", lib)
	print("Example worlds written to ", examples)
	quit()


static func _copy_dir(from: String, to: String) -> void:
	DirAccess.make_dir_recursive_absolute(to)
	for f in DirAccess.get_files_at(from):
		DirAccess.copy_absolute(from.path_join(f), to.path_join(f))


func _write_manifest() -> void:
	manifest["floors"] = {"file": "starter.flr", "animated": "starter-anim.flr", "tiles": FLOOR_NAMES}
	manifest["ceilings"] = {"file": "starter.cei", "tiles": CEILING_NAMES}
	manifest["walls"] = {"file": "starter.wal", "animated": "starter-anim.wal", "strips": WALL_NAMES}
	manifest["backdrops"] = [{"file": "starter-sky.bck", "name": "Mountain sky", "color": "c98f2a", "pos": 14}]
	manifest["pages"] = [{"file": "page-template.html", "name": "Page template"},
			{"file": "style.css", "name": "Page style sheet"}, {"file": "qborg.js", "name": "Page helpers (pushTo3D)"}]
	manifest["scripts"] = [{"file": "template.js", "name": "World script template"}]
	_write_text("library.json", JSON.stringify(manifest, "\t"))


static func _has(cmd: String) -> bool:
	return OS.execute("sh", ["-c", "command -v " + cmd], []) == 0


func _write(rel: String, bytes: PackedByteArray) -> void:
	var f := FileAccess.open(out.path_join(rel), FileAccess.WRITE)
	f.store_buffer(bytes)


func _write_text(rel: String, text: String) -> void:
	_write(rel, text.to_utf8_buffer())


# --- Drawing helpers ------------------------------------------------------------

static func _noise(seed: int, freq: float, type := FastNoiseLite.TYPE_SIMPLEX_SMOOTH) -> FastNoiseLite:
	var n := FastNoiseLite.new()
	n.seed = seed
	n.frequency = freq
	n.noise_type = type
	n.fractal_octaves = 4
	return n


## Seamless noise image coloured between two colours.
static func _noise_tile(seed: int, freq: float, a: Color, b: Color, w := TILE, h := TILE) -> Image:
	var src := _noise(seed, freq).get_seamless_image(w, h)
	var img := Image.create(w, h, false, Image.FORMAT_RGB8)
	for y in h:
		for x in w:
			img.set_pixel(x, y, a.lerp(b, src.get_pixel(x, y).r))
	return img


static func _fill_circle(img: Image, c: Vector2, r: float, col: Color) -> void:
	for y in range(maxi(0, int(c.y - r)), mini(img.get_height(), int(c.y + r) + 1)):
		for x in range(maxi(0, int(c.x - r)), mini(img.get_width(), int(c.x + r) + 1)):
			if Vector2(x, y).distance_to(c) <= r:
				img.set_pixel(x, y, col)


static func _fill_ellipse(img: Image, c: Vector2, rx: float, ry: float, col: Color) -> void:
	for y in range(maxi(0, int(c.y - ry)), mini(img.get_height(), int(c.y + ry) + 1)):
		for x in range(maxi(0, int(c.x - rx)), mini(img.get_width(), int(c.x + rx) + 1)):
			var d := Vector2((x - c.x) / rx, (y - c.y) / ry)
			if d.length_squared() <= 1.0:
				img.set_pixel(x, y, col)


static func _shade(img: Image, noise_seed: int, amount: float) -> void:
	var n := _noise(noise_seed, 0.08)
	for y in img.get_height():
		for x in img.get_width():
			var c := img.get_pixel(x, y)
			img.set_pixel(x, y, c.darkened(amount * (0.5 + 0.5 * n.get_noise_2d(x, y))))


## Blocks of `size` separated by mortar lines; odd rows shifted by `shift`.
static func _masonry(img: Image, block: Vector2i, shift: int, mortar: Color, width := 3) -> void:
	for y in img.get_height():
		var row := y / block.y
		var off := shift if row % 2 == 1 else 0
		for x in img.get_width():
			if y % block.y < width or (x + off) % block.x < width:
				img.set_pixel(x, y, mortar)


# --- Animated tiles --------------------------------------------------------------
# Each takes a phase in [0, 1) and loops seamlessly.

static func _water_tile(phase: float) -> Image:
	var water := _noise_tile(4, 0.03, Color("#1b4f8a"), Color("#3c8fd0"))
	for y in TILE:
		for x in TILE:
			# Ripples drift one wave period (32 px) per loop.
			var v := posmod(int(y + 10.0 * sin(x * TAU / TILE * 2.0 + phase * TAU) + phase * 32.0), 32)
			if v < 2:
				water.set_pixel(x, y, Color("#8fd0ff"))
	return water


static func _pad_tile(phase: float) -> Image:
	var pad := _noise_tile(7, 0.05, Color("#141a2e"), Color("#23305a"))
	var pulse := 0.5 + 0.5 * sin(phase * TAU)
	var glow := Color("#3f8fb0").lerp(Color("#bff4ff"), pulse)
	for y in TILE:
		for x in TILE:
			var d := Vector2(x, y).distance_to(Vector2(128, 128))
			if absf(d - 90 - pulse * 6.0) < 10 or absf(d - 50 + pulse * 4.0) < 5:
				pad.set_pixel(x, y, glow)
	return pad


static func _lava_tile(phase: float) -> Image:
	# Scrolls diagonally across its own seamless noise.
	var src := _noise(18, 0.02).get_seamless_image(TILE, TILE)
	var img := Image.create(TILE, TILE, false, Image.FORMAT_RGB8)
	var shift := int(phase * TILE)
	for y in TILE:
		for x in TILE:
			var v := src.get_pixel((x + shift) % TILE, (y + shift / 2) % TILE).r
			var c := Color("#3a0a04").lerp(Color("#d4380d"), smoothstep(0.2, 0.55, v))
			if v > 0.62:
				c = c.lerp(Color("#ffd23f"), smoothstep(0.62, 0.8, v))
			img.set_pixel(x, y, c)
	return img


static func _waterfall_face(phase: float) -> Image:
	# Vertical streaks falling one image height per loop.
	var src := _noise(19, 0.03).get_seamless_image(256, 256)
	var img := Image.create(256, 1024, false, Image.FORMAT_RGB8)
	var fall := int(phase * 256)
	for y in 1024:
		for x in 256:
			var v := src.get_pixel(x, posmod(y / 4 - fall, 256)).r
			img.set_pixel(x, y, Color("#1d5f9a").lerp(Color("#e8f6ff"), smoothstep(0.35, 0.8, v)))
	return img


## Stacks tiles (floor, 256x256 each) or faces (wall, rotated into 1024x256
## strips) into one atlas image.
static func _stack(parts: Array, walls: bool) -> Image:
	var img := Image.create(1024 if walls else TILE, 256 * parts.size(), false, Image.FORMAT_RGB8)
	for i in parts.size():
		var part: Image = parts[i]
		if walls:
			part = part.duplicate()
			part.rotate_90(COUNTERCLOCKWISE)
		img.blit_rect(part, Rect2i(Vector2i.ZERO, part.get_size()), Vector2i(0, i * 256))
	return img


## Writes frames as a looping animated GIF (the format the original browser
## animated) via ffmpeg: one shared palette, and later frames store only the
## rectangles that change, so still tiles cost nothing. Much smaller than APNG
## for these noisy textures. Without ffmpeg the first frame is written as a
## still PNG, so references still work.
func _write_animation(rel: String, frames: Array[Image]) -> void:
	var target := out.path_join(rel)
	if not have_ffmpeg:
		_write(rel, frames[0].save_png_to_buffer())
		return
	var tmp := OS.get_cache_dir().path_join("openqborg-anim")
	DirAccess.make_dir_recursive_absolute(tmp)
	for i in frames.size():
		frames[i].save_png(tmp.path_join("f%02d.png" % i))
	var code := OS.execute("ffmpeg", ["-loglevel", "error", "-y", "-framerate", "1000/%d" % ANIM_MS,
			"-i", tmp.path_join("f%02d.png"), "-vf",
			"split[a][b];[a]palettegen=stats_mode=full[p];[b][p]paletteuse=dither=sierra2_4a:diff_mode=rectangle",
			"-gifflags", "+transdiff", "-fflags", "+bitexact", "-loop", "0", "-f", "gif", target], [])
	for i in frames.size():
		DirAccess.remove_absolute(tmp.path_join("f%02d.png" % i))
	if code != 0:
		_write(rel, frames[0].save_png_to_buffer())


# --- Textures -------------------------------------------------------------------

func _make_textures() -> void:
	var tiles: Array[Image] = []
	tiles.append(_noise_tile(1, 0.04, Color("#2f6b2a"), Color("#6fae3d")))                  # GRASS
	var path := _noise_tile(2, 0.05, Color("#8a7a62"), Color("#c8b48c"))
	var cells := _noise(3, 0.03, FastNoiseLite.TYPE_CELLULAR)
	cells.cellular_return_type = FastNoiseLite.RETURN_DISTANCE2_SUB
	var cell_img := cells.get_seamless_image(TILE, TILE)
	for y in TILE:
		for x in TILE:
			if cell_img.get_pixel(x, y).r < 0.12:
				path.set_pixel(x, y, Color("#5b5040"))
	tiles.append(path)                                                                      # PATH
	tiles.append(_water_tile(0.0))                                                          # WATER
	var stone := _noise_tile(5, 0.06, Color("#55555c"), Color("#8a8a92"))
	_masonry(stone, Vector2i(128, 128), 64, Color("#2c2c30"), 4)
	tiles.append(stone)                                                                     # STONE
	var plate := _noise_tile(6, 0.1, Color("#6d7680"), Color("#aab4be"))
	plate.fill_rect(Rect2i(0, 0, TILE, 12), Color("#3a4048"))
	plate.fill_rect(Rect2i(0, TILE - 12, TILE, 12), Color("#3a4048"))
	plate.fill_rect(Rect2i(0, 0, 12, TILE), Color("#3a4048"))
	plate.fill_rect(Rect2i(TILE - 12, 0, 12, TILE), Color("#3a4048"))
	for p in [Vector2(32, 32), Vector2(224, 32), Vector2(32, 224), Vector2(224, 224)]:
		_fill_circle(plate, p, 10, Color("#d8dde2"))
	tiles.append(plate)                                                                     # PLATE
	tiles.append(_pad_tile(0.0))                                                            # PAD
	tiles.append(_noise_tile(8, 0.05, Color("#c9b47a"), Color("#efe0a8")))                  # SAND
	var planks := _noise_tile(9, 0.02, Color("#6b4423"), Color("#a8743f"))
	for y in TILE:
		for x in TILE:
			var board := y / 32
			var seam := (x + board * 97) % 256
			if y % 32 < 2 or seam < 2:
				planks.set_pixel(x, y, Color("#3b2412"))
	tiles.append(planks)                                                                    # PLANKS
	tiles.append(_noise_tile(10, 0.06, Color("#c9d6e6"), Color("#ffffff")))                # SNOW
	tiles.append(_noise_tile(11, 0.07, Color("#4a3322"), Color("#7a5a3a")))                # DIRT
	tiles.append(_lava_tile(0.0))                                                           # LAVA
	# starter.flr is still (a JPEG, like the originals); starter-anim.flr is an
	# animated GIF of the same tiles with water, pad and lava moving.
	_write("domains/starter.flr", _stack(tiles, false).save_jpg_to_buffer(0.9))
	var flr_frames: Array[Image] = []
	for f in ANIM_FRAMES:
		var phase := float(f) / ANIM_FRAMES
		var frame_tiles := tiles.duplicate()
		frame_tiles[Floor.WATER] = _water_tile(phase)
		frame_tiles[Floor.PAD] = _pad_tile(phase)
		frame_tiles[Floor.LAVA] = _lava_tile(phase)
		flr_frames.append(_stack(frame_tiles, false))
	_write_animation("domains/starter-anim.flr", flr_frames)

	# Wall faces are 256 wide and 1024 tall (top to bottom); the .wal file
	# stores each one rotated a quarter turn into a 1024x256 strip.
	var faces: Array[Image] = []
	var brick := _noise_tile(11, 0.05, Color("#7a2f22"), Color("#b5523a"), 256, 1024)
	_masonry(brick, Vector2i(64, 32), 32, Color("#c9bba6"), 3)
	_shade(brick, 12, 0.3)
	faces.append(brick)
	var hedge := _noise_tile(13, 0.09, Color("#16401a"), Color("#4f8f35"), 256, 1024)
	faces.append(hedge)
	var stone_wall := _noise_tile(14, 0.05, Color("#4e4e56"), Color("#85858f"), 256, 1024)
	_masonry(stone_wall, Vector2i(128, 64), 64, Color("#26262a"), 4)
	faces.append(stone_wall)
	var gate := Image.create(256, 1024, false, Image.FORMAT_RGB8)
	gate.fill(Color("#0d0d12"))
	for x in range(8, 256, 36):
		gate.fill_rect(Rect2i(x, 0, 10, 1024), Color("#5c5f66"))
	for y in range(40, 1024, 160):
		gate.fill_rect(Rect2i(0, y, 256, 12), Color("#5c5f66"))
	faces.append(gate)
	var wood := _noise_tile(15, 0.03, Color("#5a3a1e"), Color("#9a6a3a"), 256, 1024)
	for y in 1024:
		for x in 256:
			if x % 32 < 3:
				wood.set_pixel(x, y, Color("#2e1c0c"))
	faces.append(wood)
	var marble := _noise_tile(16, 0.02, Color("#d8d6d0"), Color("#fbfaf6"), 256, 1024)
	var veins := _noise(17, 0.015)
	for y in 1024:
		for x in 256:
			if absf(veins.get_noise_2d(x, y)) < 0.02:
				marble.set_pixel(x, y, Color("#8f8a80"))
	_masonry(marble, Vector2i(256, 256), 0, Color("#b8b4aa"), 2)
	faces.append(marble)
	faces.append(_waterfall_face(0.0))
	_write("domains/starter.wal", _stack(faces, true).save_jpg_to_buffer(0.9))
	var wal_frames: Array[Image] = []
	for f in ANIM_FRAMES:
		var frame_faces := faces.duplicate()
		frame_faces[Wall.WATERFALL - 1] = _waterfall_face(float(f) / ANIM_FRAMES)
		wal_frames.append(_stack(frame_faces, true))
	_write_animation("domains/starter-anim.wal", wal_frames)

	_write("domains/starter.cei", _stack(_ceiling_tiles(), false).save_jpg_to_buffer(0.9))
	_write("domains/starter-sky.bck", _panorama().save_jpg_to_buffer(0.9))


## Ceiling tiles, seen from below (Ceiling enum order).
func _ceiling_tiles() -> Array[Image]:
	var out_tiles: Array[Image] = []
	# Wooden beams: dark boards crossed by two heavy beams.
	var beams := _noise_tile(30, 0.03, Color("#3b2412"), Color("#6b4423"))
	for y in TILE:
		for x in TILE:
			if y % 32 < 2:
				beams.set_pixel(x, y, Color("#24160a"))
	for bx in [40, 168]:
		beams.fill_rect(Rect2i(bx, 0, 48, TILE), Color("#5a3a1e"))
		beams.fill_rect(Rect2i(bx, 0, 4, TILE), Color("#2e1c0c"))
		beams.fill_rect(Rect2i(bx + 44, 0, 4, TILE), Color("#2e1c0c"))
	out_tiles.append(beams)
	# Plaster: warm white with hairline cracks.
	var plaster := _noise_tile(31, 0.04, Color("#d9d2c3"), Color("#f4efe4"))
	var cracks := _noise(32, 0.01)
	for y in TILE:
		for x in TILE:
			if absf(cracks.get_noise_2d(x, y)) < 0.012:
				plaster.set_pixel(x, y, Color("#a79f90"))
	out_tiles.append(plaster)
	# Stone vault: blocks with diagonal ribs meeting in a boss.
	var vault := _noise_tile(33, 0.06, Color("#4e4e56"), Color("#7a7a84"))
	_masonry(vault, Vector2i(64, 64), 32, Color("#2c2c30"), 3)
	for k in TILE:
		for w in range(-6, 7):
			vault.set_pixel(clampi(k + w, 0, TILE - 1), k, Color("#9a9aa4"))
			vault.set_pixel(clampi(TILE - 1 - k + w, 0, TILE - 1), k, Color("#9a9aa4"))
	_fill_circle(vault, Vector2(128, 128), 18, Color("#b8b8c2"))
	_fill_circle(vault, Vector2(128, 128), 8, Color("#6e6e78"))
	out_tiles.append(vault)
	# Cave rock: dark lumpy stone.
	var cave := _noise_tile(34, 0.05, Color("#1e1b18"), Color("#4a433c"))
	var lumps := _noise(35, 0.02, FastNoiseLite.TYPE_CELLULAR).get_seamless_image(TILE, TILE)
	for y in TILE:
		for x in TILE:
			cave.set_pixel(x, y, cave.get_pixel(x, y).darkened(0.5 * (1.0 - lumps.get_pixel(x, y).r)))
	out_tiles.append(cave)
	# Starry night: deep blue with stars (for open-roofed halls).
	var stars := _noise_tile(36, 0.02, Color("#050816"), Color("#152050"))
	var srng := RandomNumberGenerator.new()
	srng.seed = 36
	for i in 90:
		var p := Vector2(srng.randf_range(2, TILE - 3), srng.randf_range(2, TILE - 3))
		_fill_circle(stars, p, srng.randf_range(0.6, 1.8), Color(1, 1, 0.9).lerp(Color("#9fc4ff"), srng.randf()))
	out_tiles.append(stars)
	# Stained glass: bright cells in dark lead.
	var glass := Image.create(TILE, TILE, false, Image.FORMAT_RGB8)
	var cell_noise := _noise(37, 0.011, FastNoiseLite.TYPE_CELLULAR)
	cell_noise.fractal_type = FastNoiseLite.FRACTAL_NONE
	cell_noise.cellular_return_type = FastNoiseLite.RETURN_CELL_VALUE
	var edge_noise := _noise(37, 0.011, FastNoiseLite.TYPE_CELLULAR)
	edge_noise.fractal_type = FastNoiseLite.FRACTAL_NONE
	edge_noise.cellular_return_type = FastNoiseLite.RETURN_DISTANCE2_SUB
	var cells := cell_noise.get_seamless_image(TILE, TILE)
	var edges := edge_noise.get_seamless_image(TILE, TILE)
	var palette := [Color("#c0392b"), Color("#2e86c1"), Color("#f1c40f"), Color("#27ae60"), Color("#8e44ad"), Color("#e67e22")]
	for y in TILE:
		for x in TILE:
			var c: Color = palette[int(cells.get_pixel(x, y).r * 97.0) % palette.size()]
			glass.set_pixel(x, y, Color("#1a1a1a") if edges.get_pixel(x, y).r < 0.16 else c.lightened(0.15))
	out_tiles.append(glass)
	# Ornate tiles: cream squares with gold rosettes.
	var ornate := _noise_tile(38, 0.08, Color("#e8dcc0"), Color("#f6efdc"))
	_masonry(ornate, Vector2i(64, 64), 0, Color("#9c7a3c"), 3)
	for cy in range(32, TILE, 64):
		for cx in range(32, TILE, 64):
			_fill_circle(ornate, Vector2(cx, cy), 14, Color("#c9a24a"))
			_fill_circle(ornate, Vector2(cx, cy), 7, Color("#7a1f1f"))
	out_tiles.append(ornate)
	return out_tiles


## A 1024x160 sky and mountain panorama that wraps horizontally.
func _panorama() -> Image:
	var w := 1024
	var h := 160
	var img := Image.create(w, h, false, Image.FORMAT_RGB8)
	var ridge := _noise(21, 1.2)
	var clouds := _noise(22, 2.5)
	for x in w:
		var a := x * TAU / w
		# Sampling on a circle makes the noise wrap seamlessly.
		var r1 := ridge.get_noise_2d(cos(a) * 1.0, sin(a) * 1.0)
		var top := int(h * 0.55 - r1 * 45.0)
		for y in h:
			var col := Color("#2a6fc9").lerp(Color("#bfe3ff"), float(y) / h)
			var c := clouds.get_noise_3d(cos(a) * 1.5, sin(a) * 1.5, y * 0.02)
			# Rows above the image repeat its top row, so keep that row cloud-free.
			if y > 14 and y < h * 0.5 and c > 0.25:
				col = col.lerp(Color.WHITE, clampf((c - 0.25) * 3.0, 0.0, 0.85))
			if y >= top:
				col = Color("#3d5a78").lerp(Color("#5d7f63"), clampf(float(y - top) / 40.0, 0.0, 1.0))
			img.set_pixel(x, y, col)
	return img


func _make_emblem(file: String, text: String, a: Color, b: Color) -> void:
	var path := examples.path_join("domains").path_join(file)
	if have_magick:
		var code := OS.execute("magick", ["-size", "256x72", "gradient:#%s-#%s" % [a.to_html(false), b.to_html(false)],
				"-gravity", "center", "-pointsize", "30", "-fill", "white", "-stroke", "#00000060",
				"-strokewidth", "2", "-annotate", "+0+0", text, "png:" + path], [])
		if code == 0:
			return
	var img := Image.create(256, 72, false, Image.FORMAT_RGB8)
	for y in 72:
		for x in 256:
			img.set_pixel(x, y, a.lerp(b, float(x) / 256))
	_fill_circle(img, Vector2(36, 36), 22, Color.WHITE)
	img.fill_rect(Rect2i(72, 26, 160, 20), Color(1, 1, 1, 0.8))
	_write("domains/" + file, img.save_png_to_buffer())


# --- Sprites --------------------------------------------------------------------

func _sprite(name: String, frames: Array[Image], world: Vector2i, z := 0, anim_ms := 0) -> CWSprite:
	var cell := frames[0].get_size()
	var s := CWSprite.new()
	s.image = Image.create(cell.x, cell.y * frames.size(), false, Image.FORMAT_RGB8)
	for i in frames.size():
		s.image.blit_rect(frames[i], Rect2i(Vector2i.ZERO, cell), Vector2i(0, i * cell.y))
	s.cell_count = frames.size()
	s.cell_width = cell.x
	s.cell_height = cell.y
	s.world_width = world.x
	s.world_height = world.y
	s.world_z = z
	s.frame_count = frames.size()
	s.animate_on_load = anim_ms > 0 and frames.size() > 1
	s.default_duration = maxi(anim_ms, 66)
	s.frame_durations = PackedInt32Array()
	for i in frames.size():
		s.frame_durations.append(s.default_duration)
	return s


## Writes objects/<file> and lists it in library.json. `blocks`: the editor
## also marks the tile unwalkable when placing it.
## Writes an animated GIF as a sprite (no CWS block: OpenQBORG takes frames,
## timing and size from the GIF itself) and lists it in library.json.
func _save_gif_sprite(file: String, frames: Array[Image], ms: int, title: String, category: String, blocks: bool) -> void:
	if not have_ffmpeg:
		_save_sprite(file, _sprite(file, frames, frames[0].get_size() * 2, 0, ms), title, category, blocks)
		return
	var tmp := OS.get_cache_dir().path_join("openqborg-gif")
	DirAccess.make_dir_recursive_absolute(tmp)
	for i in frames.size():
		frames[i].save_png(tmp.path_join("f%02d.png" % i))
	OS.execute("ffmpeg", ["-loglevel", "error", "-y", "-framerate", "1000/%d" % ms, "-i", tmp.path_join("f%02d.png"),
			"-vf", "split[a][b];[a]palettegen=reserve_transparent=0[p];[b][p]paletteuse=dither=none",
			"-fflags", "+bitexact", "-loop", "0", "-f", "gif", out.path_join("objects").path_join(file)], [])
	for i in frames.size():
		DirAccess.remove_absolute(tmp.path_join("f%02d.png" % i))
	if out == lib:
		manifest.sprites.append({"file": file, "name": title, "category": category, "blocks": blocks})


func _save_sprite(file: String, s: CWSprite, title := "", category := "Objects", blocks := false) -> void:
	_write("objects/" + file, s.to_png_bytes())
	if out == lib:
		manifest.sprites.append({"file": file, "name": title if not title.is_empty() else file.get_basename(),
				"category": category, "blocks": blocks})


static func _canvas(w: int, h: int) -> Image:
	var img := Image.create(w, h, false, Image.FORMAT_RGB8)
	img.fill(KEY)
	return img


func _make_sprites() -> void:
	# Tree
	var tree := _canvas(96, 160)
	tree.fill_rect(Rect2i(42, 96, 14, 64), Color("#5b3a1e"))
	for blob in [[Vector2(48, 60), 40, "#1f5c24"], [Vector2(30, 80), 26, "#27702c"],
			[Vector2(66, 80), 26, "#27702c"], [Vector2(48, 44), 30, "#338a38"], [Vector2(40, 34), 14, "#4aa94c"]]:
		_fill_circle(tree, blob[0], blob[1], Color(blob[2]))
	_save_sprite("tree.sprite", _sprite("tree", [tree], Vector2i(192, 320)), "Tree", "Nature", true)

	# Torch: four flickering frames
	var torch: Array[Image] = []
	for f in 4:
		var t := _canvas(32, 80)
		t.fill_rect(Rect2i(13, 30, 6, 50), Color("#4a3322"))
		t.fill_rect(Rect2i(9, 26, 14, 6), Color("#6b6f78"))
		var sway: int = [0, 2, -1, 1][f]
		_fill_ellipse(t, Vector2(16 + sway, 16), 8, 12 + f % 2 * 2, Color("#ff7a1a"))
		_fill_ellipse(t, Vector2(16 + sway, 19), 4, 7, Color("#ffe066"))
		torch.append(t)
	_save_sprite("torch.sprite", _sprite("torch", torch, Vector2i(40, 100), 0, 120), "Torch (animated)", "Lights")

	# Fountain: three splash frames
	var fountain: Array[Image] = []
	for f in 3:
		var t := _canvas(128, 112)
		_fill_ellipse(t, Vector2(64, 92), 60, 18, Color("#7c7f88"))
		_fill_ellipse(t, Vector2(64, 88), 50, 12, Color("#3c8fd0"))
		t.fill_rect(Rect2i(58, 40, 12, 50), Color("#8e919a"))
		_fill_ellipse(t, Vector2(64, 40), 24, 8, Color("#8e919a"))
		for d in 6:
			var ang := d * TAU / 6 + f * 0.35
			_fill_circle(t, Vector2(64 + cos(ang) * (18 + f * 6), 30 - sin(ang) * 6 + f * 4), 3, Color("#bfe7ff"))
		_fill_ellipse(t, Vector2(64, 26 - f * 2), 5, 10, Color("#d8f2ff"))
		fountain.append(t)
	_save_sprite("fountain.sprite", _sprite("fountain", fountain, Vector2i(220, 190), 0, 180), "Fountain (animated)", "Features", true)

	# Portal: six swirling frames
	var portal: Array[Image] = []
	for f in 6:
		var t := _canvas(96, 144)
		_fill_ellipse(t, Vector2(48, 72), 44, 68, Color("#2b1450"))
		for arm in 3:
			for k in 30:
				var ang := arm * TAU / 3 + k * 0.18 + f * TAU / 18
				var r := k * 1.3
				_fill_circle(t, Vector2(48 + cos(ang) * r, 72 + sin(ang) * r * 1.5), 3.5, Color("#b98cff").lerp(Color("#7fe3ff"), k / 30.0))
		portal.append(t)
	_save_sprite("portal.sprite", _sprite("portal", portal, Vector2i(160, 240), 0, 90), "Portal (animated)", "Features")

	# Signpost
	var sign := _canvas(64, 72)
	sign.fill_rect(Rect2i(28, 30, 8, 42), Color("#5b3a1e"))
	sign.fill_rect(Rect2i(4, 6, 56, 30), Color("#c89b5c"))
	sign.fill_rect(Rect2i(4, 6, 56, 3), Color("#8a6435"))
	for y in [15, 22, 29]:
		sign.fill_rect(Rect2i(12, y, 40, 2), Color("#5b3a1e"))
	_save_sprite("sign.sprite", _sprite("sign", [sign], Vector2i(100, 112)), "Signpost", "Features", true)

	# Wall banner: only drawn on the south face of wall blocks.
	var banner := _canvas(64, 128)
	banner.fill_rect(Rect2i(4, 0, 56, 108), Color("#1d4f8c"))
	for x in range(4, 60):
		var drop := 108 + int(12 - absf(x - 32) * 0.45)
		banner.fill_rect(Rect2i(x, 108, 1, maxi(0, drop - 108)), Color("#1d4f8c"))
	_fill_circle(banner, Vector2(32, 44), 16, Color("#f5c03f"))
	# Pixel (0, 0) is the colour key, so the rod stops short of the corner.
	banner.fill_rect(Rect2i(2, 0, 60, 6), Color("#c9a24a"))
	var b := _sprite("banner", [banner], Vector2i(64, 128), 90)
	b.on_south = true
	_save_sprite("banner.sprite", b, "Wall banner (on walls)", "Walls")

	# Orb: four pulsing frames, floating
	var orb: Array[Image] = []
	for f in 4:
		var t := _canvas(48, 48)
		var r: int = 14 + [0, 2, 3, 2][f]
		_fill_circle(t, Vector2(24, 24), r + 5, Color("#3b1d8c"))
		_fill_circle(t, Vector2(24, 24), r, Color("#a63ff5"))
		_fill_circle(t, Vector2(19, 19), 5, Color("#f0dcff"))
		orb.append(t)
	_save_sprite("orb.sprite", _sprite("orb", orb, Vector2i(72, 72), 50, 150), "Floating orb (animated)", "Features")

	# Campfire: an animated GIF sprite (OpenQBORG reads GIF/APNG/MJPEG sprites).
	var fire_frames: Array[Image] = []
	for f in 6:
		var t := _canvas(80, 96)
		for k in 5:
			var ang := k * 0.6 - 1.2
			t.fill_rect(Rect2i(int(38 + sin(ang) * 26), 80 + int(cos(ang) * 4), 24, 7), Color("#5b3a1e"))
		var sway := sin(f * TAU / 6.0) * 4.0
		_fill_ellipse(t, Vector2(40 + sway, 56), 22, 30 + f % 2 * 3, Color("#e2461b"))
		_fill_ellipse(t, Vector2(40 - sway * 0.6, 62), 14, 20, Color("#ff9a1f"))
		_fill_ellipse(t, Vector2(40 + sway * 0.3, 68), 7, 11, Color("#ffe066"))
		fire_frames.append(t)
	_save_gif_sprite("campfire.sprite", fire_frames, 110, "Campfire (animated GIF)", "Lights", true)

	# Rock
	var rock := _canvas(96, 64)
	_fill_ellipse(rock, Vector2(48, 44), 44, 20, Color("#5f5f66"))
	_fill_ellipse(rock, Vector2(40, 36), 30, 18, Color("#7c7c85"))
	_fill_ellipse(rock, Vector2(34, 30), 12, 7, Color("#9a9aa3"))
	_save_sprite("rock.sprite", _sprite("rock", [rock], Vector2i(150, 100)), "Rock", "Nature", true)

	# Bush
	var bush := _canvas(96, 64)
	for blob in [[Vector2(28, 40), 22, "#1f5c24"], [Vector2(66, 40), 22, "#1f5c24"],
			[Vector2(48, 30), 26, "#2d7a31"], [Vector2(40, 24), 10, "#4aa94c"]]:
		_fill_circle(bush, blob[0], blob[1], Color(blob[2]))
	_save_sprite("bush.sprite", _sprite("bush", [bush], Vector2i(150, 100)), "Bush", "Nature", true)

	# Flowers
	var flowers := _canvas(96, 40)
	for i in 14:
		var x := 6 + i * 6.3
		flowers.fill_rect(Rect2i(int(x), 18, 2, 22), Color("#2d7a31"))
		_fill_circle(flowers, Vector2(x + 1, 16 - (i % 3) * 3), 4,
				[Color("#ff5a7a"), Color("#ffd23f"), Color("#b98cff"), Color("#ffffff")][i % 4])
	_save_sprite("flowers.sprite", _sprite("flowers", [flowers], Vector2i(200, 84)), "Flowers", "Nature")

	# Lamp post: two flicker frames
	var lamp: Array[Image] = []
	for f in 2:
		var t := _canvas(40, 160)
		t.fill_rect(Rect2i(17, 40, 6, 120), Color("#2c2f36"))
		t.fill_rect(Rect2i(10, 150, 20, 10), Color("#2c2f36"))
		t.fill_rect(Rect2i(8, 12, 24, 30), Color("#2c2f36"))
		t.fill_rect(Rect2i(11, 15, 18, 24), Color("#ffe9a0") if f == 0 else Color("#ffd870"))
		t.fill_rect(Rect2i(6, 6, 28, 7), Color("#2c2f36"))
		lamp.append(t)
	_save_sprite("lamp.sprite", _sprite("lamp", lamp, Vector2i(64, 256), 0, 400), "Lamp post", "Lights", true)

	# Crate
	var crate := _canvas(64, 64)
	crate.fill_rect(Rect2i(2, 2, 60, 60), Color("#8a5a2b"))
	for e in [Rect2i(2, 2, 60, 6), Rect2i(2, 56, 60, 6), Rect2i(2, 2, 6, 60), Rect2i(56, 2, 6, 60)]:
		crate.fill_rect(e, Color("#5b3a1e"))
	for k in 50:
		crate.fill_rect(Rect2i(8 + k, 8 + k, 5, 5), Color("#5b3a1e"))
	crate.set_pixel(0, 0, KEY)
	_save_sprite("crate.sprite", _sprite("crate", [crate], Vector2i(110, 110)), "Crate", "Objects", true)

	# Treasure chest
	var chest := _canvas(80, 64)
	chest.fill_rect(Rect2i(4, 22, 72, 40), Color("#7a4a22"))
	_fill_ellipse(chest, Vector2(40, 24), 36, 14, Color("#8a5a2b"))
	chest.fill_rect(Rect2i(4, 24, 72, 5), Color("#d8a93a"))
	chest.fill_rect(Rect2i(34, 24, 12, 16), Color("#d8a93a"))
	chest.fill_rect(Rect2i(38, 30, 4, 5), Color("#3b2412"))
	_save_sprite("chest.sprite", _sprite("chest", [chest], Vector2i(120, 96)), "Treasure chest", "Objects", true)


# --- Audio ----------------------------------------------------------------------

static func _pcm16(samples: PackedFloat32Array) -> PackedByteArray:
	var data := PackedByteArray()
	data.resize(samples.size() * 2)
	for i in samples.size():
		data.encode_s16(i * 2, int(clampf(samples[i], -1.0, 1.0) * 32000.0))
	return data


## Saves mono samples as WAV, or through ffmpeg as `ext` with `codec`.
## Returns the file name written under media/.
func _save_audio(base: String, samples: PackedFloat32Array, ext := "wav", codec: Array = []) -> String:
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = RATE
	wav.data = _pcm16(samples)
	var wav_path := out.path_join("media/%s.wav" % base)
	wav.save_to_wav(wav_path)
	if ext == "wav" or not have_ffmpeg:
		return base + ".wav"
	var target := out.path_join("media/%s.%s" % [base, ext])
	# bitexact: no random stream serials or encoder tags, so regenerating
	# doesn't churn the files in git.
	var args := ["-loglevel", "error", "-y", "-i", wav_path, "-fflags", "+bitexact", "-flags", "+bitexact"]
	args.append_array(codec)
	args.append(target)
	if OS.execute("ffmpeg", args, []) == 0:
		DirAccess.remove_absolute(wav_path)
		return "%s.%s" % [base, ext]
	return base + ".wav"


## Loops cleanly: the tail is crossfaded into the head.
static func _loopable(s: PackedFloat32Array, fade_sec := 0.25) -> PackedFloat32Array:
	var n := int(fade_sec * RATE)
	var outp := s.slice(0, s.size() - n)
	for i in n:
		var t := float(i) / n
		outp[i] = s[i] * t + s[s.size() - n + i] * (1.0 - t)
	return outp


static func _midi_hz(note: float) -> float:
	return 440.0 * pow(2.0, (note - 69.0) / 12.0)


func _make_audio() -> void:
	# Fountain: filtered noise with droplets (classic .wav sound tile).
	var fountain := PackedFloat32Array()
	var lp := 0.0
	for i in int(RATE * 3.25):
		lp += (rng.randf_range(-1, 1) - lp) * 0.08
		fountain.append(lp * 0.9)
	for d in 40:
		var at := rng.randi_range(0, fountain.size() - 2000)
		var f := rng.randf_range(900, 2200)
		for k in 1500:
			fountain[at + k] += sin(TAU * f * k / RATE * (1.0 + k / 3000.0)) * exp(-k / 250.0) * 0.25
	audio_names["fountain"] = _save_audio("fountain", _loopable(fountain), "wav")

	# Puzzle: an eerie drone (Opus) and an ambient pad (Ogg Vorbis).
	var hum := PackedFloat32Array()
	for i in RATE * 4:
		var t := float(i) / RATE
		var lfo := 0.6 + 0.4 * sin(TAU * t * 0.5)
		hum.append((sin(TAU * 110.0 * t) * 0.35 + sin(TAU * 165.0 * t) * 0.2 + sin(TAU * 221.0 * t) * 0.1) * lfo)
	audio_names["hum"] = _save_audio("hum", hum, "opus", ["-c:a", "libopus", "-b:a", "48k"])
	audio_names["ambient"] = _save_audio("ambient", _pad([57, 53, 60, 55], 4.0, 0.0), "ogg",
			["-c:a", "libvorbis", "-q:a", "3"])

	# Sprawl: ocean swells (FLAC) and a travelling tune (AAC in .m4a).
	var waves := PackedFloat32Array()
	lp = 0.0
	for i in RATE * 6:
		var t := float(i) / RATE
		lp += (rng.randf_range(-1, 1) - lp) * 0.05
		waves.append(lp * (0.25 + 0.75 * pow(sin(PI * t / 6.0), 2.0)))
	audio_names["waves"] = _save_audio("waves", waves, "flac", ["-c:a", "flac"])
	audio_names["voyage"] = _save_audio("voyage", _pad([62, 57, 59, 55], 4.0, 1.0), "m4a",
			["-c:a", "aac", "-b:a", "96k"])

	_write("media/theme.mid", _theme_midi())

	# More loops for the library.
	var wind := PackedFloat32Array()
	lp = 0.0
	var lp2 := 0.0
	for i in RATE * 8:
		var t := float(i) / RATE
		lp += (rng.randf_range(-1, 1) - lp) * 0.02
		lp2 += (lp - lp2) * 0.3
		wind.append(lp2 * 2.2 * (0.45 + 0.55 * sin(TAU * t / 8.0) * sin(TAU * t / 8.0)))
	audio_names["wind"] = _save_audio("wind", _loopable(wind, 0.5), "ogg", ["-c:a", "libvorbis", "-q:a", "3"])
	var birds := PackedFloat32Array()
	birds.resize(RATE * 6)
	for c in 18:
		var at := rng.randi_range(0, birds.size() - RATE / 2)
		var f0 := rng.randf_range(2200, 3800)
		var notes := rng.randi_range(2, 5)
		for n in notes:
			var start := at + n * 1800
			for k in 1400:
				if start + k >= birds.size():
					break
				var sweep := f0 * (1.0 + 0.35 * sin(PI * k / 1400.0))
				birds[start + k] += sin(TAU * sweep * k / RATE) * sin(PI * k / 1400.0) * 0.22
	audio_names["birds"] = _save_audio("birds", _loopable(birds, 0.3), "ogg", ["-c:a", "libvorbis", "-q:a", "4"])
	var fire := PackedFloat32Array()
	lp = 0.0
	for i in RATE * 4:
		lp += (rng.randf_range(-1, 1) - lp) * 0.04
		var v := lp * 0.6
		if rng.randf() < 0.0015:
			v += rng.randf_range(-0.9, 0.9)
		fire.append(v)
	audio_names["fire"] = _save_audio("fire", _loopable(fire, 0.2), "wav")

	for s in [["fountain", "Fountain"], ["waves", "Ocean waves"], ["hum", "Eerie drone"],
			["wind", "Wind"], ["birds", "Birdsong"], ["fire", "Campfire"]]:
		manifest.sounds.append({"file": audio_names[s[0]], "name": s[1]})
	manifest.music.append({"file": "theme.mid", "name": "Courtyard theme (MIDI)"})
	manifest.music.append({"file": audio_names["ambient"], "name": "Ambient pad"})
	manifest.music.append({"file": audio_names["voyage"], "name": "Voyage"})


## Four chords of `bar` seconds each (root MIDI notes, minor/major picked by
## shape), with an optional arpeggio on top.
func _pad(roots: Array, bar: float, arp: float) -> PackedFloat32Array:
	var s := PackedFloat32Array()
	var total := int(RATE * bar * roots.size())
	s.resize(total)
	for c in roots.size():
		var root: int = roots[c]
		var chord := [root, root + (3 if c % 2 == 0 else 4), root + 7, root + 12]
		var start := int(c * bar * RATE)
		for i in int(bar * RATE):
			var t := float(i) / RATE
			var env := minf(1.0, t / 0.6) * minf(1.0, (bar - t) / 0.6)
			var v := 0.0
			for n in chord:
				var hz := _midi_hz(n - 12)
				v += sin(TAU * hz * t) * 0.12 + sin(TAU * hz * 1.003 * t) * 0.08
			if arp > 0.0:
				var step := int(t / 0.25)
				var note: int = chord[step % chord.size()] + 12
				var nt := fmod(t, 0.25)
				var tri := 2.0 * absf(2.0 * fmod(nt * _midi_hz(note), 1.0) - 1.0) - 1.0
				v += tri * exp(-nt * 9.0) * 0.18 * arp
			s[start + i] = v * env
	return s


## A short General MIDI tune: vibraphone melody over strings (format 0).
func _theme_midi() -> PackedByteArray:
	var ppq := 96
	var events: Array = [] # [tick, bytes]
	var tempo := 60000000 / 104
	events.append([0, PackedByteArray([0xff, 0x51, 3, (tempo >> 16) & 0xff, (tempo >> 8) & 0xff, tempo & 0xff])])
	events.append([0, PackedByteArray([0xc0, 11])])   # ch1 vibraphone
	events.append([0, PackedByteArray([0xc1, 48])])   # ch2 strings
	var progression := [[57, 60, 64], [53, 57, 60], [48, 52, 55], [55, 59, 62]]
	var chords := progression + progression
	var melody := [76, 72, 69, 72, 74, 72, 69, 67, 72, 69, 65, 69, 72, 74, 76, 72,
			72, 67, 64, 67, 71, 67, 74, 71, 76, 74, 72, 69, 67, 69, 72, 76]
	for bar in chords.size():
		var t0: int = bar * ppq * 4
		for n in chords[bar]:
			events.append([t0, PackedByteArray([0x91, n, 60])])
			events.append([t0 + ppq * 4 - 4, PackedByteArray([0x81, n, 0])])
		for k in 4:
			var n: int = melody[(bar * 4 + k) % melody.size()]
			events.append([t0 + k * ppq, PackedByteArray([0x90, n, 88])])
			events.append([t0 + k * ppq + ppq - 12, PackedByteArray([0x80, n, 0])])
	events.sort_custom(func(a, b): return a[0] < b[0])
	var track := PackedByteArray()
	var last := 0
	for e in events:
		track.append_array(_vlq(e[0] - last))
		track.append_array(e[1])
		last = e[0]
	track.append_array(PackedByteArray([0, 0xff, 0x2f, 0]))
	var smf := "MThd".to_ascii_buffer()
	smf.append_array(PackedByteArray([0, 0, 0, 6, 0, 0, 0, 1, (ppq >> 8) & 0xff, ppq & 0xff]))
	smf.append_array("MTrk".to_ascii_buffer())
	var n := track.size()
	smf.append_array(PackedByteArray([(n >> 24) & 0xff, (n >> 16) & 0xff, (n >> 8) & 0xff, n & 0xff]))
	smf.append_array(track)
	return smf


static func _vlq(v: int) -> PackedByteArray:
	var bytes := PackedByteArray([v & 0x7f])
	v >>= 7
	while v > 0:
		bytes.insert(0, (v & 0x7f) | 0x80)
		v >>= 7
	return bytes


# --- Pages ----------------------------------------------------------------------

func _page(file: String, title: String, body: String) -> void:
	_write_text("html/" + file, """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>%s</title>
<link rel="stylesheet" href="style.css">
<script src="qborg.js"></script>
</head>
<body>
<h1>%s</h1>
%s
</body>
</html>
""" % [title, title, body])


func _shortcut(file: String, page: String) -> void:
	# Classic Internet Shortcut; "http://../" is how CYBERWORLD's tools wrote
	# links relative to the domains/ folder.
	_write_text("domains/" + file, "[InternetShortcut]\r\nURL=http://../html/%s\r\n" % page)


func _make_library_pages() -> void:
	_write_text("html/style.css", """body { margin: 0; padding: 12px 14px; background: #10141f; color: #e8ecf4;
  font: 15px/1.45 system-ui, sans-serif; }
h1 { font-size: 20px; margin: 0 0 10px; color: #7fc4ff; }
h2 { font-size: 16px; margin: 14px 0 6px; color: #f5c03f; }
a, button { color: #7fc4ff; }
button { background: #1d2a44; border: 1px solid #3c5a8a; border-radius: 6px; padding: 6px 10px;
  margin: 4px 4px 4px 0; font: inherit; cursor: pointer; }
button:hover { background: #274070; }
kbd { background: #222a3a; border: 1px solid #3a4560; border-radius: 4px; padding: 0 5px; }
canvas { width: 100%; border-radius: 8px; background: #05070d; }
.note { color: #9aa6bd; font-size: 13px; }
""")
	_write_text("html/qborg.js", """// Page helpers, compatible with the original CYBERWORLD browser: they
// navigate to borg:// URLs, which OpenQBORG (and the old browser) intercept.
function pushTo3D(borg) {
  var slashes = location.protocol.indexOf("http") === 0 ? "//" : "///";
  var here = location.href.substring(location.href.indexOf(slashes) + slashes.length,
      location.href.lastIndexOf("/") + 1);
  location = "borg://" + here + borg;
}
function pushTo2D(html) {
  location = "borg://cmd.web@" + location.href.substring(0, location.href.lastIndexOf("/") + 1) + html;
}
""")
	_write_text("html/page-template.html", """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>My page</title>
<link rel="stylesheet" href="style.css">
<script src="qborg.js"></script>
</head>
<body>
<h1>My page</h1>
<p>Pages like this one show beside your world (gtw2/gtw3 links) or in its place
(gtw doorways). They are ordinary HTML5: add images, canvas, audio, anything.</p>
<p><button onclick="pushTo3D('../other-world.borg')">Go to another world</button></p>
<p class="note">pushTo3D() and pushTo2D() come from qborg.js and work in the original
CYBERWORLD browser too.</p>
</body>
</html>
""")
	_write_text("scripts/template.js", """// A world script: see docs/SCRIPTING.md for the full borg API.
// Paint trigger ids with the editor's "Script triggers" layer.

borg.on("load", (world) => {
  borg.message(`Welcome to !`);
});

borg.on("enter", ({ x, y, id }) => {
  if (id === 1) {
    borg.message(`You stepped on trigger 1 at ,.`);
  }
});

borg.on("click", ({ x, y, id }) => {
  if (id === 2) {
    // Example: open a door by flattening a wall block and making it walkable.
    borg.setTile("hgt", x, y - 1, 0);
    borg.setTile("wal", x, y - 1, 0);
  }
});
""")


func _make_pages() -> void:
	_page("welcome.html", "Hello, QBORG", """<p>Welcome to the OpenQBORG example courtyard: a <em>classic</em>
16&times;16 world that the original CYBERWORLD tools could open.</p>
<canvas id="sky" width="300" height="110"></canvas>
<h2>Getting around</h2>
<p><kbd>&uarr;</kbd><kbd>&darr;</kbd> or <kbd>W</kbd><kbd>S</kbd> walk, <kbd>&larr;</kbd><kbd>&rarr;</kbd> turn,
<kbd>A</kbd><kbd>D</kbd> strafe, <kbd>PgUp</kbd><kbd>PgDn</kbd> look. Click a tile to use it.</p>
<p>Walk up to the signposts to read more. The swirling portals lead to the
other examples, or jump straight there:</p>
<button onclick="pushTo3D('../sprawl.borg')">The Sprawl (128&times;128)</button>
<button onclick="pushTo3D('../puzzle.borg')">The Orb Vault (scripted)</button>
<p class="note">This page is plain HTML5 &mdash; the starfield above is a &lt;canvas&gt; animation.</p>
<script>
var c = document.getElementById("sky"), g = c.getContext("2d"), stars = [];
for (var i = 0; i < 90; i++) stars.push([Math.random() * 300, Math.random() * 110, Math.random() * 1.5 + 0.3]);
(function frame(t) {
  g.fillStyle = "#05070d"; g.fillRect(0, 0, 300, 110);
  stars.forEach(function (s) {
    s[0] = (s[0] + s[2] * 0.4) % 300;
    g.fillStyle = "rgba(200,225,255," + (0.4 + 0.6 * Math.abs(Math.sin(t / 700 + s[1]))) + ")";
    g.fillRect(s[0], s[1], s[2], s[2]);
  });
  requestAnimationFrame(frame);
})(0);
</script>""")
	_page("info.html", "How this courtyard is built", """<p>A QBORG world is a grid of tiles with several layers:</p>
<ul>
<li><b>Floors</b> come from one image of stacked 256&times;256 tiles.</li>
<li><b>Walls</b> are blocks with a height; brick and hedge use different strips.</li>
<li><b>Objects</b> are sprites: the trees, animated torches, the fountain, and the
blue banners painted onto the north wall.</li>
<li><b>Links</b>: the portals are doorways (<code>gtw</code>); standing near a sign shows a
page here (<code>gtw2</code>).</li>
<li><b>Sound</b>: the fountain is a looping WAV sound tile, and the whole courtyard is a
MIDI music region.</li>
</ul>
<p class="note">Open examples/borgs/hello.borg in the OpenQBORG Editor to see every layer.</p>""")
	_page("move.html", "Pages can change the world", """<p>World pages can talk back to the 3D view through
<code>window.external</code>, just like in 2000. Try it:</p>
<button onclick="window.external.MoveTile('SPRITE', 12, 11, 13, 11, false)">Move the torch east</button>
<button onclick="window.external.MoveTile('SPRITE', 13, 11, 12, 11, false)">Move it back</button>
<p class="note">Host version: <span id="ver"></span></p>
<script>
document.getElementById("ver").textContent =
  (window.external && window.external.GetVer) ? window.external.GetVer() : "(not in a QBORG player)";
</script>""")
	_page("sprawl.html", "The Sprawl", """<p>A 128&times;128 island &mdash; 64 times the area of a classic world, made
possible by OpenQBORG's <code>&lt;size&gt;</code> extension.</p>
<p>Listen along the shore: the waves are FLAC sound tiles, and the music is AAC
in an .m4a file. A little way up the path, just to your right, a portal leads home.</p>
<button onclick="pushTo3D('../hello.borg')">Back to the courtyard</button>""")
	_page("puzzle.html", "The Orb Vault", """<p>This vault runs a JavaScript world script (<code>scripts/puzzle.js</code>).</p>
<h2>Your task</h2>
<ol><li>Collect the <b>three orbs</b>. One is behind a wall: step on the glowing
pad to teleport.</li><li>Stand on the <b>metal plate</b> to open the gate.</li>
<li>Take the portal home.</li></ol>
<p class="note">The drone near the plate is an Opus sound tile; the music is Ogg Vorbis.</p>""")
	_shortcut("welcome.url", "welcome.html")
	_shortcut("info.url", "info.html")
	_shortcut("move.url", "move.html")
	_shortcut("sprawl.url", "sprawl.html")
	_shortcut("puzzle.url", "puzzle.html")


# --- Worlds ---------------------------------------------------------------------

func _base_level(w: int, h: int, title: String, description: String) -> BorgLevel:
	var level := BorgLevel.create_empty(w, h)
	level.meta["Title"] = title
	level.meta["Description"] = description
	level.meta["Date"] = "2026-09-29"
	level.meta["Rights"] = "OpenQBORG examples, GPL-3.0-or-later"
	level.ext.clear()
	var offsets := PackedInt64Array()
	for i in Floor.size():
		offsets.append(i * TILE * TILE)
	level.set_ext_cfil("flr", "starter-anim.flr", offsets)
	var strips := PackedInt64Array()
	for i in Wall.size():
		strips.append(i * 256 * 1024)
	level.set_ext_cfil("wal", "starter-anim.wal", strips)
	return level


func _finish(level: BorgLevel, file: String, nav: Image, emblem: String) -> void:
	_write("domains/" + file.get_basename() + ".nav", nav.save_jpg_to_buffer(0.9))
	level.ext.append({"tag": "nav", "attrs": {}, "items": [{"kind": "file", "href": file.get_basename() + ".nav", "text": ""}]})
	level.ext.append({"tag": "emb", "attrs": {}, "items": [{"kind": "file", "href": emblem, "text": ""}]})
	# Classic <ext> order, as CYBERWORLD's tools wrote it; extensions last.
	var order := ["flr", "cei", "wal", "nav", "emb", "bdp", "pal", "spr", "gtw", "gtw2", "gtw3", "wav", "mid", "js"]
	level.ext.sort_custom(func(a, b): return order.find(a.tag) < order.find(b.tag))
	level.save_file(out.path_join(file))
	print("  %-12s %dx%d" % [file, level.width, level.height])


## Renders a nav map: one colour per tile, `px` pixels per tile.
static func _nav(level: BorgLevel, px: int) -> Image:
	var colors := {Floor.GRASS: Color("#4f8f35"), Floor.PATH: Color("#c8b48c"), Floor.WATER: Color("#2e6fb5"),
			Floor.STONE: Color("#77777f"), Floor.PLATE: Color("#aab4be"), Floor.PAD: Color("#7fe3ff"),
			Floor.SAND: Color("#e3d196")}
	var img := Image.create(level.width * px, level.height * px, false, Image.FORMAT_RGB8)
	for y in level.height:
		for x in level.width:
			var c: Color = colors.get(level.get_cell("flr", x, y), Color.BLACK)
			var h := level.get_cell("hgt", x, y)
			if h > 0:
				c = Color("#2b1d1a") if level.get_cell("wal", x, y) != Wall.HEDGE else Color("#1d3f1c")
			elif level.get_cell("obj", x, y) > 0:
				c = c.darkened(0.35)
			if level.get_cell("gtw", x, y) > 0:
				c = Color("#b98cff")
			img.fill_rect(Rect2i(x * px, y * px, px, px), c)
	return img


## Applies an ASCII map. `legend` maps a character to {layer: value}.
static func _paint(level: BorgLevel, rows: PackedStringArray, legend: Dictionary) -> Dictionary:
	var found := {}
	assert(rows.size() == level.height)
	for y in rows.size():
		assert(rows[y].length() == level.width, "row %d is %d wide" % [y, rows[y].length()])
		for x in rows[y].length():
			var ch := rows[y][x]
			if not found.has(ch):
				found[ch] = []
			found[ch].append(Vector2i(x, y))
			for layer in legend.get(ch, {}):
				level.set_cell(layer, x, y, legend[ch][layer])
	return found


func _make_hello() -> void:
	var level := _base_level(16, 16, "Hello QBORG", "OpenQBORG example: classic courtyard")
	level.set_ext_files("spr", PackedStringArray(["tree.sprite", "torch.sprite", "fountain.sprite",
			"portal.sprite", "sign.sprite", "banner.sprite"]))
	var rows := PackedStringArray([
		"################",
		"#TT.....=....TT#",
		"#T......=.....T#",
		"#..hhhh.=.hhh..#",
		"#..h....=...h..#",
		"#..h.t..=.i.h..#",
		"#.......=......#",
		"#P======F=====Q#",
		"#.......=......#",
		"#..~~~..=..s...#",
		"#..~~~..=..t2..#",
		"#.......=......#",
		"#.T.....=....T.#",
		"#.......=......#",
		"#.......S......#",
		"################",
	])
	var g := Floor.GRASS
	var p := Floor.PATH
	var legend := {
		"#": {"flr": p, "hgt": 64, "wal": Wall.BRICK},
		"h": {"flr": g, "hgt": 24, "wal": Wall.HEDGE},
		".": {"flr": g}, "2": {"flr": g}, "=": {"flr": p}, "S": {"flr": p},
		"~": {"flr": Floor.WATER, "wal": 1},
		"T": {"flr": g, "obj": 1, "wal": 1},
		"t": {"flr": g, "obj": 2},
		"F": {"flr": p, "obj": 3, "wal": 1, "wav": 1},
		"P": {"flr": p, "obj": 4, "gtw": 1},
		"Q": {"flr": p, "obj": 4, "gtw": 2},
		"i": {"flr": g, "obj": 5, "wal": 1},
		"s": {"flr": g, "obj": 5, "wal": 1},
	}
	var at := _paint(level, rows, legend)
	# A waterfall in the north wall, behind the fountain.
	for x in range(6, 10):
		level.set_cell("wal", x, 0, Wall.WATERFALL)
	# Banners painted on the inside (south) face of the north wall.
	for x in [4, 11]:
		level.set_cell("obj", x, 0, 6)
	# Standing next to a sign shows its page in the side pane.
	for board in [["i", 1], ["s", 2]]:
		var c: Vector2i = at[board[0]][0]
		for dy in range(-1, 2):
			for dx in range(-1, 2):
				level.set_cell("gtw2", c.x + dx, c.y + dy, board[1])
	for y in level.height:
		for x in level.width:
			level.set_cell("mid", x, y, 1)
	var start: Vector2i = at["S"][0]
	level.set_start_tile_position(Vector2(start) + Vector2(0.5, 0.5))
	level.set_start_yaw(0.0)
	level.start_pos[2] = 20
	var bdp := level.ensure_ext("bdp")
	bdp.attrs = {"BC": "c98f2a", "POS": "14"}
	bdp.items = [{"kind": "file", "href": "starter-sky.bck", "text": ""}]
	level.set_ext_files("gtw", PackedStringArray(["sprawl", "puzzle"]))
	level.set_ext_files("gtw2", PackedStringArray(["info.url", "move.url"]))
	level.set_ext_files("gtw3", PackedStringArray(["welcome.url"]))
	level.set_ext_files("wav", PackedStringArray([audio_names["fountain"]]))
	level.set_ext_files("mid", PackedStringArray(["theme.mid"]))
	_finish(level, "hello.borg", _nav(level, 9), "hello.emb")


func _make_sprawl() -> void:
	var n := 128
	var level := _base_level(n, n, "The Sprawl", "OpenQBORG example: 128x128 island (<size> extension)")
	level.set_ext_files("spr", PackedStringArray(["tree.sprite", "portal.sprite", "torch.sprite", "campfire.sprite"]))
	var terrain := _noise(7, 0.035)
	var c := Vector2(n / 2.0, n / 2.0)
	for y in n:
		for x in n:
			var d := Vector2(x, y).distance_to(c) / (n / 2.0)
			var v := terrain.get_noise_2d(x, y) * 0.6 + 0.55 - d * d * 1.1
			if Vector2(x, y).distance_to(c) < 7:
				v = 1.0
			if v < 0.0:
				level.set_cell("flr", x, y, Floor.WATER)
				level.set_cell("wal", x, y, 1)
			elif v < 0.08:
				level.set_cell("flr", x, y, Floor.SAND)
			else:
				level.set_cell("flr", x, y, Floor.GRASS)
	# Cross-shaped paths from the centre, while on land.
	for dir in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
		var p := Vector2i(c)
		while level.in_bounds(p.x, p.y) and level.get_cell("flr", p.x, p.y) != Floor.WATER:
			level.set_cell("flr", p.x, p.y, Floor.PATH)
			p += dir
	# Ruined stone rings and trees on the grass.
	for i in 26:
		var r := Vector2i(rng.randi_range(8, n - 12), rng.randi_range(8, n - 12))
		if Vector2(r).distance_to(c) < 12:
			continue
		var gap := rng.randi_range(0, 7)
		var k := 0
		for dy in 4:
			for dx in 4:
				if (dx == 0 or dy == 0 or dx == 3 or dy == 3) and level.get_cell("flr", r.x + dx, r.y + dy) == Floor.GRASS:
					if k != gap:
						level.set_cell("hgt", r.x + dx, r.y + dy, rng.randi_range(12, 48))
						level.set_cell("wal", r.x + dx, r.y + dy, Wall.STONE)
					k += 1
		level.set_cell("obj", r.x + 1, r.y + 1, 3) # a torch inside each ruin
	for y in n:
		for x in n:
			if level.get_cell("flr", x, y) == Floor.GRASS and level.get_cell("hgt", x, y) == 0 \
					and level.get_cell("obj", x, y) == 0 and rng.randf() < 0.07 \
					and Vector2(x, y).distance_to(c) > 5:
				level.set_cell("obj", x, y, 1)
				level.set_cell("wal", x, y, 1)
	# Waves: sound tiles on some sand next to water.
	var shore := 0
	for y in range(0, n, 3):
		for x in range(0, n, 3):
			if shore < 48 and level.get_cell("flr", x, y) == Floor.SAND:
				level.set_cell("wav", x, y, 1)
				shore += 1
	for y in n:
		for x in n:
			level.set_cell("mid", x, y, 1)
	# A campfire (an animated GIF sprite) beside the path, just ahead.
	var fire := Vector2i(c) + Vector2i(-1, -3)
	level.set_cell("obj", fire.x, fire.y, 4)
	level.set_cell("wal", fire.x, fire.y, 1)
	level.set_cell("flr", fire.x, fire.y, Floor.DIRT)
	var home := Vector2i(c) + Vector2i(1, -4)
	level.set_cell("obj", home.x, home.y, 2)
	level.set_cell("gtw", home.x, home.y, 1)
	level.set_cell("flr", home.x, home.y, Floor.PAD)
	level.set_start_tile_position(c + Vector2(0.5, 0.5))
	level.set_start_yaw(0.0)
	level.start_pos[2] = 20
	var bdp := level.ensure_ext("bdp")
	bdp.attrs = {"BC": "c98f2a", "POS": "14"}
	bdp.items = [{"kind": "file", "href": "starter-sky.bck", "text": ""}]
	level.set_ext_files("gtw", PackedStringArray(["hello"]))
	level.set_ext_files("gtw3", PackedStringArray(["sprawl.url"]))
	level.set_ext_files("wav", PackedStringArray([audio_names["waves"]]))
	level.set_ext_files("mid", PackedStringArray([audio_names["voyage"]]))
	_finish(level, "sprawl.borg", _nav(level, 2), "sprawl.emb")


func _make_puzzle() -> void:
	var level := _base_level(16, 16, "The Orb Vault", "OpenQBORG example: JavaScript world scripting")
	var offsets := PackedInt64Array()
	for i in Floor.size():
		offsets.append(i * TILE * TILE)
	var cei_offsets := PackedInt64Array()
	for i in Ceiling.size():
		cei_offsets.append(i * TILE * TILE)
	level.set_ext_cfil("cei", "starter.cei", cei_offsets)
	level.set_ext_files("spr", PackedStringArray(["orb.sprite", "torch.sprite", "portal.sprite"]))
	var rows := PackedStringArray([
		"################",
		"#o.....##......#",
		"#......##..o...#",
		"#..A...##...B..#",
		"#......##......#",
		"#t.....##.....t#",
		"###.############",
		"#t............t#",
		"#..o...........#",
		"#.......p......#",
		"#..............#",
		"#.......S......#",
		"#######GG#######",
		"#......X.......#",
		"#..............#",
		"################",
	])
	var st := Floor.STONE
	var legend := {
		"#": {"flr": st, "hgt": 64, "wal": Wall.STONE},
		"G": {"flr": st, "hgt": 64, "wal": Wall.GATE},
		".": {"flr": st}, "S": {"flr": st},
		"o": {"flr": st, "obj": 1, "js": 1},
		"t": {"flr": st, "obj": 2},
		"A": {"flr": Floor.PAD, "js": 3},
		"B": {"flr": Floor.PAD, "js": 4},
		"p": {"flr": Floor.PLATE, "js": 2, "wav": 1},
		"X": {"flr": Floor.PAD, "obj": 3, "gtw": 1},
	}
	var at := _paint(level, rows, legend)
	for y in level.height:
		for x in level.width:
			level.set_cell("cei", x, y, Ceiling.VAULT)
			level.set_cell("mid", x, y, 1)
	var start: Vector2i = at["S"][0]
	level.set_start_tile_position(Vector2(start) + Vector2(0.5, 0.5))
	level.set_start_yaw(0.0)
	level.start_pos[2] = 20
	level.ensure_ext("bdp").attrs = {"BC": "180c0c", "POS": "0"}
	level.set_ext_files("gtw", PackedStringArray(["hello"]))
	level.set_ext_files("gtw3", PackedStringArray(["puzzle.url"]))
	level.set_ext_files("wav", PackedStringArray([audio_names["hum"]]))
	level.set_ext_files("mid", PackedStringArray([audio_names["ambient"]]))
	level.set_ext_files("js", PackedStringArray(["puzzle.js"]))

	var a: Vector2i = at["A"][0]
	var b: Vector2i = at["B"][0]
	var gates: Array = at["G"].map(func(v): return [v.x, v.y])
	_write_text("scripts/puzzle.js", """// The Orb Vault: collect three orbs, then stand on the plate to open the gate.
// Trigger ids (painted on the editor's "Script triggers" layer):
//   1 orb, 2 plate, 3 pad A (west), 4 pad B (east)
const ORBS = %d;
const GATE = %s;
const PAD_A_EXIT = [%d.5, %d.5];   // step off beside pad A
const PAD_B_EXIT = [%d.5, %d.5];   // step off beside pad B
let collected = 0;
let open = false;

borg.on("load", () => {
  borg.message(`Find the ${ORBS} orbs. The glowing pad is a teleporter.`);
});

borg.on("enter", ({ x, y, id }) => {
  switch (id) {
    case 1:                                   // an orb
      borg.setTile("obj", x, y, 0);
      borg.setTile("js", x, y, 0);
      collected++;
      borg.message(collected < ORBS ? `Orb ${collected} of ${ORBS}.` : "All orbs found! Now the plate.");
      break;
    case 2:                                   // the pressure plate
      if (open) break;
      if (collected < ORBS) {
        borg.message(`The plate won't budge. ${ORBS - collected} orb(s) to go.`);
        break;
      }
      for (const [gx, gy] of GATE) {
        borg.setTile("hgt", gx, gy, 0);
        borg.setTile("wal", gx, gy, 0);
      }
      open = true;
      borg.message("The gate grinds open. The portal leads home.");
      break;
    case 3:
      borg.teleport(...PAD_B_EXIT);
      break;
    case 4:
      borg.teleport(...PAD_A_EXIT);
      break;
  }
});

borg.on("click", ({ id }) => {
  if (id === 2) borg.message(open ? "The gate is open." : `${collected}/${ORBS} orbs.`);
});
""" % [at["o"].size(), JSON.stringify(gates), a.x, a.y + 1, b.x, b.y + 1])
	_finish(level, "puzzle.borg", _nav(level, 9), "puzzle.emb")
