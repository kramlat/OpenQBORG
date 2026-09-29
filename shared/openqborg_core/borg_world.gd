# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 Mark Toman and OpenQBORG contributors
class_name BorgWorld
extends Node3D
## Builds and animates the 3D scene for a BorgLevel.
##
## World units: 1.0 = one tile (256 CYBERWORLD pixels). Tile (x, y) covers
## [x, x+1] on X and [y, y+1] on Z; the floor is at Y = 0.
##
## Floors, ceilings and walls are batched into one mesh per material and
## colliders are merged into row runs, so 256x256 worlds stay cheap.
##
## Asset folders relative to the .borg file (as the original tools wrote them):
##   domains/  floor/ceiling/wall strips, nav map, emblem, backdrop, .url links
##   objects/  .sprite / .ctrl
##   media/    .wav / .mid
##   scripts/  .js (OpenQBORG extension)

signal geometry_rebuilt

const PX := 1.0 / BorgLevel.TILE_PX
const WALL_STRIP_HEIGHT := 256
const COLLIDER_HEIGHT := 8.0

## Page-script layer names -> .borg map layers.
const SCRIPT_LAYERS := {"SPRITE": "obj", "FLOOR": "flr", "NOWALK": "wal",
		"WALL": "hgt", "LINK": "gtw", "LINK2": "gtw2", "CEILING": "cei"}

var level: BorgLevel
var base_url := ""
var ceiling_height := 1.0
var nav_image: Image
var emblem_image: Image
var backdrop_image: Image
## Per wav index: AudioStream or null.
var sounds: Array = []
## World scripts (OpenQBORG extension): [{name, source}].
var scripts: Array = []
var fetcher: BorgFetcher
## Camera used to pick faces for multi-sided sprites.
var viewer: Node3D

var _sprites: Array = []
var _animated: Array = []
var _floor_tiles: Texture2DArray
var _floor_tile_count := 0
var _ceiling_tiles: Texture2DArray
var _ceiling_tile_count := 0
var _wall_strips: Array = []
var _wall_mat_cache := {}
var _content: Node3D


func domains_url(href: String) -> String:
	return BorgUrl.join(base_url, "domains/" + href)


func objects_url(href: String) -> String:
	return BorgUrl.join(base_url, "objects/" + href)


func media_url(href: String) -> String:
	return BorgUrl.join(base_url, "media/" + href)


func scripts_url(href: String) -> String:
	return BorgUrl.join(base_url, "scripts/" + href)


## Loads every asset the level references and builds the scene.
## `url` is the fetchable URL of the .borg itself.
func build(p_level: BorgLevel, url: String, p_fetcher: BorgFetcher) -> void:
	level = p_level
	fetcher = p_fetcher
	base_url = BorgUrl.dir_of(url)
	ceiling_height = level.ceiling_height_px() * PX

	nav_image = await _load_image(domains_url(level.ext_file("nav")))
	emblem_image = await _load_image(domains_url(level.ext_file("emb")))
	var bdp := level.find_ext("bdp")
	if not bdp.is_empty():
		for item in bdp.items:
			if item.kind == "file":
				backdrop_image = await _load_image(domains_url(item.href))

	var flr := await _load_surface_tiles("flr")
	_floor_tiles = flr.array
	_floor_tile_count = flr.count
	var cei := await _load_surface_tiles("cei")
	_ceiling_tiles = cei.array
	_ceiling_tile_count = cei.count
	await _load_wall_strips()
	for href in level.ext_files("spr"):
		var bytes := await fetcher.fetch(objects_url(href))
		_sprites.append(CWSprite.decode(bytes, href) if not bytes.is_empty() else null)
	for href in level.ext_files("wav"):
		var stream := BorgAudio.decode(await fetcher.fetch(media_url(href)), href)
		if stream == null:
			push_warning(BorgAudio.last_error)
		else:
			BorgAudio.set_looping(stream)
		sounds.append(stream)
	for href in level.ext_files("js"):
		var source := await fetcher.fetch_text(scripts_url(href))
		if not source.is_empty():
			scripts.append({"name": href, "source": source})
	rebuild()


## (Re)builds geometry from `level` without refetching any assets.
func rebuild() -> void:
	if _content != null:
		_content.free()
	_animated.clear()
	_content = Node3D.new()
	_content.name = "Content"
	add_child(_content)
	_build_surfaces()
	_build_walls()
	_build_colliders()
	_build_sprites()
	_build_sounds()
	geometry_rebuilt.emit()


func tile_of(pos: Vector3) -> Vector2i:
	return Vector2i(floori(pos.x), floori(pos.z))


func in_bounds(t: Vector2i) -> bool:
	return level.in_bounds(t.x, t.y)


# --- Asset loading -----------------------------------------------------------

func _load_image(url: String) -> Image:
	if url.ends_with("/"):
		return null
	return decode_image(await fetcher.fetch(url))


static func decode_image(bytes: PackedByteArray) -> Image:
	if bytes.size() < 12:
		return null
	var img := Image.new()
	var err := ERR_FILE_UNRECOGNIZED
	if bytes[0] == 0x89 and bytes[1] == 0x50:
		err = img.load_png_from_buffer(bytes)
	elif bytes[0] == 0xff and bytes[1] == 0xd8:
		err = img.load_jpg_from_buffer(bytes)
	elif bytes[0] == 0x42 and bytes[1] == 0x4d:
		err = img.load_bmp_from_buffer(bytes)
	elif bytes.slice(8, 12).get_string_from_ascii() == "WEBP":
		err = img.load_webp_from_buffer(bytes)
	return img if err == OK else null


static func unshaded_material(tex: Texture2D) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.albedo_texture = tex
	return m


## Floor/ceiling images are 256-wide stacks of 256x256 tiles; the cfil offsets
## are pixel offsets (y * width + x) of each tile's top-left corner.
## Returns {array: Texture2DArray (one layer per tile) or null, count}.
func _load_surface_tiles(tag: String) -> Dictionary:
	var none := {"array": null, "count": 0}
	var cfil := level.ext_cfil(tag)
	if cfil.is_empty():
		return none
	var img := await _load_image(domains_url(cfil.href))
	if img == null:
		return none
	img.convert(Image.FORMAT_RGBA8)
	var tiles: Array[Image] = []
	for off in cfil.offsets:
		var x := int(off % img.get_width())
		var y := int(off / img.get_width())
		var region := Rect2i(x, y, mini(256, img.get_width() - x), mini(256, img.get_height() - y))
		var tile: Image
		if region.size.x > 0 and region.size.y > 0:
			tile = img.get_region(region)
		else:
			tile = Image.create(256, 256, false, Image.FORMAT_RGBA8)
			tile.fill(Color.MAGENTA)
		# Array layers must all match.
		if tile.get_size() != Vector2i(256, 256):
			tile.resize(256, 256, Image.INTERPOLATE_NEAREST)
		tiles.append(tile)
	if tiles.is_empty():
		return none
	var array := Texture2DArray.new()
	array.create_from_images(tiles)
	return {"array": array, "count": tiles.size()}


## Wall images are 1024 wide. Each strip is stored sideways: the image's X
## axis runs down the wall from the top, its Y axis along the wall face.
func _load_wall_strips() -> void:
	var cfil := level.ext_cfil("wal")
	if cfil.is_empty():
		return
	var img := await _load_image(domains_url(cfil.href))
	if img == null:
		return
	for off in cfil.offsets:
		_wall_strips.append({"image": img, "x": int(off % img.get_width()), "y": int(off / img.get_width())})


func _wall_material(index: int, height_px: int) -> Material:
	var key := "%d:%d" % [index, height_px]
	if _wall_mat_cache.has(key):
		return _wall_mat_cache[key]
	var mat: StandardMaterial3D
	if index >= 0 and index < _wall_strips.size():
		var strip: Dictionary = _wall_strips[index]
		var img: Image = strip.image
		var region := Rect2i(strip.x, strip.y, mini(height_px, img.get_width() - strip.x),
				mini(WALL_STRIP_HEIGHT, img.get_height() - strip.y))
		var face := img.get_region(region)
		face.rotate_90(CLOCKWISE)
		mat = unshaded_material(ImageTexture.create_from_image(face))
	else:
		mat = unshaded_material(null)
		mat.albedo_color = Color(0.45, 0.45, 0.5)
	_wall_mat_cache[key] = mat
	return mat


# --- Batched geometry --------------------------------------------------------

## Collects quads per material, then emits one MeshInstance3D per material.
class Batcher:
	var _tools := {}
	var _mats := {}

	func quad(mat: Material, a: Vector3, b: Vector3, c: Vector3, d: Vector3) -> void:
		var id := mat.get_instance_id()
		if not _tools.has(id):
			var st := SurfaceTool.new()
			st.begin(Mesh.PRIMITIVE_TRIANGLES)
			_tools[id] = st
			_mats[id] = mat
		var st: SurfaceTool = _tools[id]
		# a=top-left, b=top-right, c=bottom-right, d=bottom-left (texture space)
		for v in [[a, Vector2(0, 0)], [b, Vector2(1, 0)], [c, Vector2(1, 1)],
				[a, Vector2(0, 0)], [c, Vector2(1, 1)], [d, Vector2(0, 1)]]:
			st.set_uv(v[1])
			st.add_vertex(v[0])

	func emit(parent: Node3D) -> void:
		for id in _tools:
			var mi := MeshInstance3D.new()
			mi.mesh = _tools[id].commit()
			mi.material_override = _mats[id]
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			parent.add_child(mi)


func _build_surfaces() -> void:
	var any_floor: bool = level.layers.has("flr") and \
			level.layers["flr"].count(BorgLevel.EMPTY_SURFACE) < level.tile_count()
	if _floor_tiles != null:
		_content.add_child(_surface_multimesh("flr", _floor_tiles, _floor_tile_count, Basis(), 0.0))
	elif any_floor and nav_image != null:
		# Levels without floor textures use the nav map stretched over the
		# grid, as the original player did.
		var batch := Batcher.new()
		var w := float(level.width)
		var d := float(level.height)
		batch.quad(unshaded_material(ImageTexture.create_from_image(nav_image)),
				Vector3(0, 0, 0), Vector3(w, 0, 0), Vector3(w, 0, d), Vector3(0, 0, d))
		batch.emit(_content)
	if _ceiling_tiles != null:
		# Flipped plane: faces down, texture mirrored like the original.
		_content.add_child(_surface_multimesh("cei", _ceiling_tiles, _ceiling_tile_count,
				Basis(Vector3.RIGHT, PI), ceiling_height))


## One MultiMesh instance per tile; INSTANCE_CUSTOM.r picks the array layer.
func _surface_multimesh(layer: String, tiles: Texture2DArray, count: int, basis: Basis,
		y_pos: float) -> MultiMeshInstance3D:
	var quad := PlaneMesh.new()
	quad.size = Vector2.ONE
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	mm.mesh = quad
	var cells: Array[Vector3i] = []
	for y in level.height:
		for x in level.width:
			var v := level.get_cell(layer, x, y)
			if v != BorgLevel.EMPTY_SURFACE and v < count:
				cells.append(Vector3i(x, y, v))
	mm.instance_count = cells.size()
	for i in cells.size():
		var c := cells[i]
		mm.set_instance_transform(i, Transform3D(basis, Vector3(c.x + 0.5, y_pos, c.y + 0.5)))
		mm.set_instance_custom_data(i, Color(c.z, 0, 0, 0))
	var mat := ShaderMaterial.new()
	mat.shader = preload("surface_tiles.gdshader")
	mat.set_shader_parameter("tiles", tiles)
	var mmi := MultiMeshInstance3D.new()
	mmi.name = "Floor" if layer == "flr" else "Ceiling"
	mmi.multimesh = mm
	mmi.material_override = mat
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mmi


func _build_walls() -> void:
	var batch := Batcher.new()
	for y in level.height:
		for x in level.width:
			var hgt := level.get_cell("hgt", x, y)
			if hgt == 0:
				continue
			var h_px := hgt * 4
			var h := h_px * PX
			var mat := _wall_material(level.get_cell("wal", x, y) - 1, h_px)
			var up := Vector3(0, h, 0)
			# Each face: [neighbour offset, left and right bottom corners as seen from outside].
			for face in [
				[Vector2i(0, -1), Vector3(x + 1, 0, y), Vector3(x, 0, y)],             # north
				[Vector2i(0, 1), Vector3(x, 0, y + 1), Vector3(x + 1, 0, y + 1)],      # south
				[Vector2i(-1, 0), Vector3(x, 0, y), Vector3(x, 0, y + 1)],             # west
				[Vector2i(1, 0), Vector3(x + 1, 0, y + 1), Vector3(x + 1, 0, y)],      # east
			]:
				var n: Vector2i = Vector2i(x, y) + face[0]
				# Skip faces hidden by an equal or taller neighbouring block.
				if in_bounds(n) and level.get_cell("hgt", n.x, n.y) >= hgt:
					continue
				batch.quad(mat, face[1] + up, face[2] + up, face[2], face[1])
	batch.emit(_content)


func _build_colliders() -> void:
	var body := StaticBody3D.new()
	body.name = "Colliders"
	_content.add_child(body)
	var w := level.width
	var d := level.height
	# World border.
	_add_box(body, Vector3(-0.5, 0, d / 2.0), Vector3(1, 0, d + 2))
	_add_box(body, Vector3(w + 0.5, 0, d / 2.0), Vector3(1, 0, d + 2))
	_add_box(body, Vector3(w / 2.0, 0, -0.5), Vector3(w + 2, 0, 1))
	_add_box(body, Vector3(w / 2.0, 0, d + 0.5), Vector3(w + 2, 0, 1))
	# Blocking tiles, merged into horizontal runs.
	for y in d:
		var run_start := -1
		for x in w + 1:
			var blocked := x < w and (level.get_cell("wal", x, y) > 0 or level.get_cell("hgt", x, y) > 0)
			if blocked and run_start < 0:
				run_start = x
			elif not blocked and run_start >= 0:
				_add_box(body, Vector3((run_start + x) / 2.0, 0, y + 0.5), Vector3(x - run_start, 0, 1))
				run_start = -1


func _add_box(body: StaticBody3D, center: Vector3, size: Vector3) -> void:
	var box := BoxShape3D.new()
	box.size = Vector3(size.x, COLLIDER_HEIGHT, size.z)
	var shape := CollisionShape3D.new()
	shape.shape = box
	shape.position = Vector3(center.x, COLLIDER_HEIGHT / 2, center.z)
	body.add_child(shape)


# --- Sprites and sounds ------------------------------------------------------

func _build_sprites() -> void:
	for y in level.height:
		for x in level.width:
			var v := level.get_cell("obj", x, y)
			if v == 0 or v > _sprites.size() or _sprites[v - 1] == null:
				continue
			var sprite: CWSprite = _sprites[v - 1]
			if level.get_cell("hgt", x, y) > 0:
				_build_wall_sprite(sprite, x, y)
			else:
				_build_billboard(sprite, x, y)


func _make_sprite3d(sprite: CWSprite) -> Sprite3D:
	var s := Sprite3D.new()
	s.texture = ImageTexture.create_from_image(sprite.image)
	s.vframes = maxi(1, mini(sprite.cell_count, sprite.image.get_height() / maxi(1, sprite.cell_height)))
	s.shaded = false
	s.alpha_cut = SpriteBase3D.ALPHA_CUT_DISCARD
	s.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	return s


func _build_billboard(sprite: CWSprite, x: int, y: int) -> void:
	var s := _make_sprite3d(sprite)
	s.billboard = BaseMaterial3D.BILLBOARD_FIXED_Y
	var world_h := sprite.world_height * PX
	s.pixel_size = world_h / maxf(1.0, sprite.cell_height)
	var sx := (sprite.world_width / maxf(1.0, sprite.cell_width)) / (sprite.world_height / maxf(1.0, sprite.cell_height))
	s.scale = Vector3(sx, 1, 1)
	s.position = Vector3(x + sprite.world_x * PX, sprite.world_z * PX + world_h / 2, y + 1 - sprite.world_y * PX)
	_content.add_child(s)
	_register_animation(s, sprite)


## A sprite on a wall tile is painted onto the block's flagged faces.
func _build_wall_sprite(sprite: CWSprite, x: int, y: int) -> void:
	var faces := []
	if sprite.on_north: faces.append([Vector3(0.5, 0, -0.002), PI])
	if sprite.on_south: faces.append([Vector3(0.5, 0, 1.002), 0.0])
	if sprite.on_west: faces.append([Vector3(-0.002, 0, 0.5), -PI / 2])
	if sprite.on_east: faces.append([Vector3(1.002, 0, 0.5), PI / 2])
	for face in faces:
		var s := _make_sprite3d(sprite)
		s.pixel_size = PX
		s.position = Vector3(x, (sprite.world_z + sprite.cell_height / 2.0) * PX, y) + face[0]
		s.rotation.y = face[1]
		_content.add_child(s)
		_register_animation(s, sprite)


func _register_animation(s: Sprite3D, sprite: CWSprite) -> void:
	if sprite.animate_on_load and sprite.frame_count > 1:
		_animated.append({"node": s, "sprite": sprite, "time": 0.0, "frame": 0})
	elif sprite.multi_sided and sprite.sides > 1:
		_animated.append({"node": s, "sprite": sprite, "time": 0.0, "frame": -1})


func _build_sounds() -> void:
	for y in level.height:
		for x in level.width:
			var v := level.get_cell("wav", x, y)
			if v == 0 or v > sounds.size() or sounds[v - 1] == null:
				continue
			var p := AudioStreamPlayer3D.new()
			p.stream = sounds[v - 1]
			p.position = Vector3(x + 0.5, 0.25, y + 0.5)
			p.max_distance = 1.5
			p.autoplay = true
			_content.add_child(p)


func _process(delta: float) -> void:
	for a in _animated:
		var sprite: CWSprite = a.sprite
		var s: Sprite3D = a.node
		if a.frame >= 0:
			a.time += delta * 1000.0
			var dur := maxi(1, sprite.frame_durations[a.frame % sprite.frame_durations.size()])
			while a.time > dur:
				a.time -= dur
				a.frame = (a.frame + 1) % sprite.frame_count
				dur = maxi(1, sprite.frame_durations[a.frame % sprite.frame_durations.size()])
			s.frame = mini(a.frame, s.vframes - 1)
		elif viewer != null:
			var to_viewer := viewer.global_position - s.global_position
			var angle := fposmod(rad_to_deg(atan2(to_viewer.x, to_viewer.z)), 360.0)
			s.frame = mini(int(round(angle / 360.0 * sprite.sides)) % sprite.sides, s.vframes - 1)


# --- Live edits (page MoveTile, world scripts, editor preview) ----------------

## Sets one tile. `layer` is a .borg layer name or a page-script alias.
func set_tile(layer: String, x: int, y: int, value: int, rebuild_now := true) -> bool:
	layer = SCRIPT_LAYERS.get(layer.to_upper(), layer.to_lower())
	if not level.in_bounds(x, y):
		return false
	level.set_cell(layer, x, y, value)
	if rebuild_now:
		rebuild()
	return true


## MoveTile(layer, fromX, fromY, toX, toY, keepOriginal); coordinates are
## 1-based as the CYBERWORLD page API used them.
func move_tile(script_layer: String, from: Vector2i, to: Vector2i, keep_original: bool) -> bool:
	var layer: String = SCRIPT_LAYERS.get(script_layer.to_upper(), script_layer.to_lower())
	from -= Vector2i.ONE
	to -= Vector2i.ONE
	if not in_bounds(from) or not in_bounds(to):
		return false
	level.set_cell(layer, to.x, to.y, level.get_cell(layer, from.x, from.y))
	if not keep_original:
		var empty := BorgLevel.EMPTY_SURFACE if layer in BorgLevel.SURFACE_LAYERS else 0
		level.set_cell(layer, from.x, from.y, empty)
	rebuild()
	return true
