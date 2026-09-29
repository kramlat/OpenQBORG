# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 Mark Toman and OpenQBORG contributors
extends Control
## OpenQBORG Player: address bar, 3D view and the CYBERWORLD-style side
## panel (emblem, nav map, page pane).
##
## Tile triggers, as the original browser behaved:
##   gtw   stepping on it follows a link: another world, or a full-view page
##   gtw2  shows a page in the side pane while standing in that region;
##         leaving it returns to the level's default page (gtw3)
##   mid   background music region
##   js    (OpenQBORG) script trigger id, sent with enter/leave/click events
## Clicking a tile activates its gtw/gtw2 link too.

const SIDE_WIDTH := 300
const HOME_TEXT := "Enter a borg:// or borgs:// address, or a path to a .borg file."

var fetcher := BorgFetcher.new()
var pages := LocalPageServer.new()
var music := BorgMusic.new()
var scripts := ScriptHost.new()
var world: BorgWorld
var walker := BorgWalker.new()
var current_url := ""
var history: PackedStringArray = []

var _address: LineEdit
var _back: Button
var _status: Label
var _viewport: SubViewport
var _view_container: SubViewportContainer
var _env: Environment
var _backdrop: ColorRect
var _emblem: TextureRect
var _nav: NavMap
var _side_page: HtmlView
var _full_page: HtmlView
var _full_page_box: VBoxContainer
var _last_tile := Vector2i(-1, -1)
var _music_file := ""
var _loading := false
var _world_dirty := false


func _ready() -> void:
	add_child(fetcher)
	add_child(pages)
	add_child(music)
	music.status_changed.connect(func(t): _status.text = t)
	_build_ui()
	add_child(scripts)
	scripts.request.connect(_on_script_request)
	var start := _startup_url()
	if start.is_empty():
		_status.text = HOME_TEXT
	else:
		open_url(start)


func _startup_url() -> String:
	for arg in OS.get_cmdline_user_args() + OS.get_cmdline_args():
		var lower := arg.to_lower()
		if lower.begins_with("borg") or lower.begins_with("http") or lower.begins_with("file://") \
				or lower.ends_with(".borg"):
			return arg
	return ""


# --- UI ----------------------------------------------------------------------

func _build_ui() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 0)
	add_child(root)

	var bar := HBoxContainer.new()
	root.add_child(bar)
	_back = Button.new()
	_back.text = "◀"
	_back.tooltip_text = "Previous world"
	_back.disabled = true
	_back.pressed.connect(go_back)
	bar.add_child(_back)
	var reload := Button.new()
	reload.text = "⟳"
	reload.tooltip_text = "Reload"
	reload.pressed.connect(func(): if not current_url.is_empty(): _load_world(current_url, false))
	bar.add_child(reload)
	_address = LineEdit.new()
	_address.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_address.placeholder_text = "borg://host/world/level.borg"
	_address.text_submitted.connect(func(t): open_url(t))
	bar.add_child(_address)
	var go := Button.new()
	go.text = "Go"
	go.pressed.connect(func(): open_url(_address.text))
	bar.add_child(go)

	var split := HSplitContainer.new()
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(split)

	var left := Control.new()
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left.clip_contents = true
	split.add_child(left)
	_view_container = SubViewportContainer.new()
	_view_container.stretch = true
	_view_container.set_anchors_preset(Control.PRESET_FULL_RECT)
	_view_container.gui_input.connect(_on_view_input)
	left.add_child(_view_container)
	_viewport = SubViewport.new()
	_viewport.handle_input_locally = false
	_view_container.add_child(_viewport)
	_setup_scene()

	# Full-view pages (gtw doorways, pushTo2D) replace the 3D view.
	_full_page_box = VBoxContainer.new()
	_full_page_box.set_anchors_preset(Control.PRESET_FULL_RECT)
	_full_page_box.visible = false
	left.add_child(_full_page_box)
	var back_to_3d := Button.new()
	back_to_3d.text = "◀ Back to 3D"
	back_to_3d.pressed.connect(_close_full_page)
	_full_page_box.add_child(back_to_3d)
	_full_page = HtmlView.new()
	_full_page.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_full_page.page_request.connect(_on_page_request)
	_full_page_box.add_child(_full_page)

	var side := VBoxContainer.new()
	side.custom_minimum_size.x = SIDE_WIDTH
	split.add_child(side)
	_emblem = TextureRect.new()
	_emblem.custom_minimum_size.y = 64
	_emblem.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_emblem.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	side.add_child(_emblem)
	_nav = NavMap.new()
	_nav.custom_minimum_size = Vector2(SIDE_WIDTH, 160)
	_nav.tile_clicked.connect(_activate_tile)
	side.add_child(_nav)
	_side_page = HtmlView.new()
	_side_page.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_side_page.page_request.connect(_on_page_request)
	side.add_child(_side_page)

	_status = Label.new()
	_status.clip_text = true
	root.add_child(_status)


func _setup_scene() -> void:
	_env = Environment.new()
	_env.background_mode = Environment.BG_COLOR
	_env.background_canvas_max_layer = -1
	var we := WorldEnvironment.new()
	we.environment = _env
	_viewport.add_child(we)
	var layer := CanvasLayer.new()
	layer.layer = -1
	_viewport.add_child(layer)
	_backdrop = ColorRect.new()
	_backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	_backdrop.material = ShaderMaterial.new()
	_backdrop.material.shader = preload("res://backdrop.gdshader")
	_backdrop.visible = false
	layer.add_child(_backdrop)
	_viewport.add_child(walker)


# --- Navigation --------------------------------------------------------------

## Handles anything typed, passed on the command line or requested by a page.
func open_url(input: String, context := "") -> void:
	var c := BorgUrl.classify(input, context if not context.is_empty() else current_url)
	c.url = pages.to_local(c.url)
	match c.kind:
		BorgUrl.Kind.COMMAND_PREV:
			go_back()
		BorgUrl.Kind.COMMAND_WEB:
			_show_full_page(c.url)
		BorgUrl.Kind.WORLD:
			var lower: String = c.url.to_lower()
			if lower.ends_with(".html") or lower.ends_with(".htm"):
				_show_full_page(c.url)
			else:
				_load_world(c.url, true)


func go_back() -> void:
	if history.size() > 0:
		var prev := history[history.size() - 1]
		history.remove_at(history.size() - 1)
		_load_world(prev, false)


func _load_world(url: String, push_history: bool) -> void:
	if _loading:
		return
	_loading = true
	_status.text = "Loading " + BorgUrl.to_display(url) + " …"
	_address.text = BorgUrl.to_display(url)
	var bytes := await fetcher.fetch(url)
	var level: BorgLevel = null if bytes.is_empty() else BorgLevel.parse(bytes.get_string_from_utf8())
	if level == null:
		_status.text = fetcher.last_error if bytes.is_empty() else "Not a QBORG world: " + url
		_address.text = BorgUrl.to_display(current_url)
		_loading = false
		return
	if BorgUrl.is_local(url):
		# Pages sit beside the borgs/ folder (../html, ../images); serve the parent.
		pages.allow_root(BorgUrl.local_path(BorgUrl.dir_of(url)).get_base_dir().get_base_dir())
	var next := BorgWorld.new()
	await next.build(level, url, fetcher)
	if push_history and not current_url.is_empty() and current_url != url:
		history.append(current_url)
	_back.disabled = history.is_empty()
	if world != null:
		world.queue_free()
	world = next
	world.viewer = walker.camera
	_viewport.add_child(world)
	current_url = url
	_side_page.borg_location = url
	_full_page.borg_location = url
	_apply_level_look()
	walker.walk_speed = maxf(1.0, level.speed() / 150.0 * 4.0)
	walker.place(level.start_tile_position(), level.start_eye_height_px() * BorgWorld.PX, level.start_yaw())
	_last_tile = Vector2i(-1, -1)
	scripts.start(world, _player_state())
	_close_full_page()
	var title: String = level.meta.get("Title", "")
	DisplayServer.window_set_title("%s — OpenQBORG" % title if not title.is_empty() else "OpenQBORG")
	_status.text = "%s   (%s)" % [title, "Chromium pages" if HtmlView.cef_available() else "no page engine"]
	_loading = false
	_maybe_screenshot()


func _apply_level_look() -> void:
	_env.background_color = world.level.background_color()
	if world.backdrop_image != null:
		var mat: ShaderMaterial = _backdrop.material
		mat.set_shader_parameter("sky", ImageTexture.create_from_image(world.backdrop_image))
		mat.set_shader_parameter("sky_size", Vector2(world.backdrop_image.get_size()))
		_backdrop.visible = true
		_env.background_mode = Environment.BG_CANVAS
	else:
		_backdrop.visible = false
		_env.background_mode = Environment.BG_COLOR
	_emblem.texture = ImageTexture.create_from_image(world.emblem_image) if world.emblem_image else null
	_nav.set_map(world.nav_image, Vector2i(world.level.width, world.level.height))


# --- Links and pages ---------------------------------------------------------

## Resolves an <ext> link entry: .url shortcut, .html page, or a world name.
## Returns {url, target}.
func _resolve_link(href: String) -> Dictionary:
	if href.is_empty():
		return {"url": "", "target": ""}
	var lower := href.to_lower()
	if lower.ends_with(".url"):
		var text := await fetcher.fetch_text(world.domains_url(href))
		var sc := BorgUrl.parse_shortcut(text)
		if sc.url.is_empty():
			return {"url": "", "target": ""}
		return {"url": BorgUrl.resolve_shortcut_target(sc.url, world.domains_url("")), "target": sc.target}
	if lower.ends_with(".html") or lower.ends_with(".htm"):
		return {"url": BorgUrl.join(world.base_url, href), "target": ""}
	return {"url": BorgUrl.join(world.base_url, href + ".borg"), "target": ""}


func _resolve_default_page() -> String:
	return (await _resolve_link(world.level.ext_file("gtw3"))).url


func _show_full_page(url: String) -> void:
	_full_page.navigate(pages.to_served(url))
	_full_page_box.visible = true
	_view_container.visible = false


func _close_full_page() -> void:
	_full_page_box.visible = false
	_view_container.visible = true


func _follow_gtw(index: int) -> void:
	var links := world.level.ext_files("gtw")
	if index < 1 or index > links.size():
		return
	var link := await _resolve_link(links[index - 1])
	if link.url.is_empty():
		return
	if link.url.to_lower().ends_with(".borg"):
		_load_world(link.url, true)
	else:
		_show_full_page(link.url)


func _show_gtw2(index: int) -> void:
	var links := world.level.ext_files("gtw2")
	if index >= 1 and index <= links.size():
		_side_page.navigate(pages.to_served((await _resolve_link(links[index - 1])).url))
	else:
		_side_page.navigate(pages.to_served(await _resolve_default_page()))


func _on_page_request(msg: Dictionary) -> void:
	match msg.type:
		"borg":
			open_url(str(msg.url), str(msg.get("base", "")))
		"world":
			_load_world(pages.to_local(BorgUrl.to_fetchable(str(msg.url), current_url)), true)
		"web":
			_show_full_page(str(msg.url))
		"moveTile":
			if world != null:
				world.move_tile(str(msg.layer), Vector2i(int(msg.fromX), int(msg.fromY)),
						Vector2i(int(msg.toX), int(msg.toY)), bool(msg.keepOriginal))
				var layer: String = BorgWorld.SCRIPT_LAYERS.get(str(msg.layer).to_upper(), str(msg.layer))
				if world.level.layers.has(layer):
					scripts.sync_layer(layer, world.level.layers[layer])
		"tileValue":
			pass # TODO: sprite height scaling (option 0/3) once a world needs it
		"dialog":
			_show_page_dialog(str(msg.get("text", "")))


# --- Per-frame triggers ------------------------------------------------------

func _process(_delta: float) -> void:
	if world == null or _loading:
		return
	if _world_dirty:
		_world_dirty = false
		world.rebuild()
	var yaw := walker.yaw
	var mat: ShaderMaterial = _backdrop.material
	mat.set_shader_parameter("view_size", Vector2(_viewport.size))
	mat.set_shader_parameter("yaw", yaw)
	mat.set_shader_parameter("horizon_offset", world.level.backdrop_offset() + walker.pitch * 983.0)
	_nav.set_player(Vector2(walker.position.x, walker.position.z), yaw)

	var tile := world.tile_of(walker.position)
	if tile == _last_tile or not world.in_bounds(tile):
		return
	var prev := _last_tile
	_last_tile = tile
	var lvl := world.level
	if scripts.is_running():
		if world.in_bounds(prev):
			scripts.send_event("leave", prev, lvl.get_cell("js", prev.x, prev.y), _player_state())
		scripts.send_event("enter", tile, lvl.get_cell("js", tile.x, tile.y), _player_state())
	var gtw := lvl.get_cell("gtw", tile.x, tile.y)
	if gtw > 0 and gtw != lvl.get_cell("gtw", prev.x, prev.y):
		_follow_gtw(gtw)
	var gtw2 := lvl.get_cell("gtw2", tile.x, tile.y)
	if gtw2 != lvl.get_cell("gtw2", prev.x, prev.y) or prev.x < 0:
		_show_gtw2(gtw2)
	var mid := lvl.get_cell("mid", tile.x, tile.y)
	var mids := lvl.ext_files("mid")
	var music_file := mids[mid - 1] if mid > 0 and mid <= mids.size() else ""
	if music_file != _music_file:
		_music_file = music_file
		music.play_url(world.media_url(music_file) if not music_file.is_empty() else "", fetcher)
		_status.text = ("♪ " + music_file) if not music_file.is_empty() else lvl.meta.get("Title", "")


func _on_view_input(event: InputEvent) -> void:
	if world == null:
		return
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_view_container.grab_focus()
		var cam := walker.camera
		var pos: Vector2 = event.position * Vector2(_viewport.size) / _view_container.size
		var origin := cam.project_ray_origin(pos)
		var dir := cam.project_ray_normal(pos)
		if dir.y < -0.001:
			var hit := origin + dir * (-origin.y / dir.y)
			_activate_tile(world.tile_of(hit))


func _activate_tile(tile: Vector2i) -> void:
	if world == null or not world.in_bounds(tile):
		return
	scripts.send_event("click", tile, world.level.get_cell("js", tile.x, tile.y), _player_state())
	var gtw := world.level.get_cell("gtw", tile.x, tile.y)
	var gtw2 := world.level.get_cell("gtw2", tile.x, tile.y)
	if gtw > 0:
		_follow_gtw(gtw)
	elif gtw2 > 0:
		_show_gtw2(gtw2)


## Dev hook: OPENQBORG_SCREENSHOT=out.png saves a frame after loading, then quits.
func _maybe_screenshot() -> void:
	var out := OS.get_environment("OPENQBORG_SCREENSHOT")
	if out.is_empty():
		return
	for i in 240:
		await get_tree().process_frame
	print("screenshot: walker=%s yaw=%.3f tile=%s" % [walker.position, walker.yaw, _last_tile])
	print("screenshot: status=%s music=%s page=%s" % [_status.text, music.current, _side_page.current_url])
	var sfx := world.find_children("*", "AudioStreamPlayer3D", true, false).map(func(p): return "%s:%s" % [p.stream.get_class(), p.playing])
	print("screenshot: music_stream=%s sfx=%s" % [music.get_child(1).stream, sfx])
	get_viewport().get_texture().get_image().save_png(out)
	get_tree().quit()


# --- World scripts (OpenQBORG extension) --------------------------------------

func _player_state() -> Dictionary:
	return {"x": walker.position.x, "y": walker.position.z, "yaw": walker.yaw}


func _on_script_request(msg: Dictionary) -> void:
	if world == null:
		return
	match msg.get("type"):
		"setTile":
			# Coalesced: many edits in one frame cost a single rebuild.
			world.set_tile(str(msg.layer), int(msg.x), int(msg.y), int(msg.value), false)
			_world_dirty = true
		"teleport":
			var yaw = msg.get("yaw")
			walker.place(Vector2(float(msg.x), float(msg.y)), walker.camera.position.y,
					walker.yaw if yaw == null else float(yaw))
		"go":
			open_url(BorgUrl.join(world.base_url, str(msg.url)))
		"showPage":
			_show_full_page(BorgUrl.join(world.base_url, str(msg.url)))
		"showSidePage":
			_side_page.navigate(pages.to_served(BorgUrl.join(world.base_url, str(msg.url))))
		"message":
			_status.text = str(msg.text)
		"log":
			print("[world script] ", msg.text)


## alert()/confirm()/prompt() from world pages, shown by Godot (native JS
## dialogs crash godot-cef).
func _show_page_dialog(text: String) -> void:
	var d := AcceptDialog.new()
	d.title = world.level.meta.get("Title", "OpenQBORG") if world != null else "OpenQBORG"
	d.dialog_text = text
	d.dialog_autowrap = true
	d.min_size = Vector2i(360, 0)
	d.confirmed.connect(d.queue_free)
	d.canceled.connect(d.queue_free)
	add_child(d)
	d.popup_centered()
