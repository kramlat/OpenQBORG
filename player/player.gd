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
var bookmarks := Bookmarks.new()
var world: BorgWorld
var walker := BorgWalker.new()
var current_url := ""
var history: PackedStringArray = []

var _address: LineEdit
var _bookmark_menu: PopupMenu
var _open_dialog: FileDialog
var _back: Button
var _status: Label
var _viewport: SubViewport
var _view_container: SubViewportContainer
var _env: Environment
var _backdrop: ColorRect
var _emblem: TextureRect
var _nav: NavMap
var _side_page: HtmlView
var _browser: BrowserView
var _forward: Button
var _last_tile := Vector2i(-1, -1)
var _music_file := ""
var _loading := false
var _world_dirty := false
var _shot_started := false
var _loading_url := ""
## Per-frame textures when the backdrop or emblem is animated.
var _backdrop_textures: Array[Texture2D] = []
var _emblem_textures: Array[Texture2D] = []
## Live web surfaces by id (see WebSurface).
var _surfaces := {}


func _ready() -> void:
	DisplayServer.window_set_min_size(Vector2i(800, 500))
	add_child(fetcher)
	add_child(pages)
	add_child(music)
	music.status_changed.connect(func(t): _status.text = t)
	HtmlView.ruffle_base = pages.ruffle_base()
	_build_ui()
	add_child(scripts)
	scripts.request.connect(_on_script_request)
	var start := _startup_url()
	if start.is_empty():
		_status.text = HOME_TEXT
	else:
		open_url(start)


func _startup_url() -> String:
	# After "--" anything goes: a world, a file, a web address.
	for arg in OS.get_cmdline_user_args():
		if not arg.begins_with("-"):
			return arg
	# Exported builds get their arguments directly (file associations, %u).
	for arg in OS.get_cmdline_args():
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
	root.add_child(_build_menu())

	var bar := HBoxContainer.new()
	root.add_child(bar)
	_back = Button.new()
	_back.text = "◀"
	_back.tooltip_text = "Back"
	_back.disabled = true
	_back.pressed.connect(_on_back)
	bar.add_child(_back)
	_forward = Button.new()
	_forward.text = "▶"
	_forward.tooltip_text = "Forward (web pages)"
	_forward.disabled = true
	_forward.pressed.connect(func(): _browser.go_forward())
	bar.add_child(_forward)
	var reload := Button.new()
	reload.text = "⟳"
	reload.tooltip_text = "Reload"
	reload.pressed.connect(_on_reload)
	bar.add_child(reload)
	_address = LineEdit.new()
	_address.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_address.placeholder_text = "borg://host/world/level.borg, a .borg file, or any web address"
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

	# The built-in browser (web pages, gtw doorway pages, pushTo2D) takes the
	# 3D view's place while it is showing.
	_browser = preload("res://browser.tscn").instantiate()
	_browser.visible = false
	left.add_child(_browser)
	_browser.page_request.connect(_on_page_request)
	_browser.close_requested.connect(_close_full_page)
	_browser.address_changed.connect(_on_browser_address)
	_browser.title_changed.connect(_on_browser_title)

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
	input = input.strip_edges()
	var lower := input.to_lower()
	var explicit_world := lower.begins_with("borg://") or lower.begins_with("borgs://")
	# A bare "example.com/page" is a web address (over TLS); a bare
	# "host/world.borg" stays a world.
	if not input.contains("://") and not input.begins_with("/") and not input.begins_with("~") \
			and not input.begins_with(".") and not HtmlView.is_world_url(input) and input.contains("."):
		_show_full_page("https://" + input)
		return
	var c := BorgUrl.classify(input, context if not context.is_empty() else current_url)
	c.url = pages.to_local(c.url)
	match c.kind:
		BorgUrl.Kind.COMMAND_PREV:
			go_back()
		BorgUrl.Kind.COMMAND_WEB:
			_show_full_page(c.url)
		BorgUrl.Kind.WORLD:
			# borg:// addresses, local paths and *.borg are worlds; any other
			# http(s) address is a web page for the built-in browser.
			var lower_url: String = str(c.url).to_lower().get_slice("?", 0).get_slice("#", 0)
			var page: bool = lower_url.ends_with(".html") or lower_url.ends_with(".htm")
			# An .html address is a page even as borg:// (Flash intros navigate
			# to their own page that way).
			var web: bool = page or (not explicit_world and not HtmlView.is_world_url(c.url) \
					and not BorgUrl.is_local(c.url))
			if web:
				if _browser.visible and pages.to_local(_browser.url()) == pages.to_local(c.url):
					return # already showing
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
	_loading_url = url
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
	_update_nav_buttons()
	_clear_surfaces()
	if world != null:
		world.queue_free()
	world = next
	world.geometry_rebuilt.connect(_sync_surfaces)
	world.viewer = walker.camera
	_viewport.add_child(world)
	current_url = url
	_side_page.borg_location = url
	_browser.html.borg_location = url
	_browser.set_world_available(true)
	_apply_level_look()
	walker.walk_speed = maxf(1.0, level.speed() / 150.0 * 4.0)
	walker.place(level.start_tile_position(), level.start_eye_height_px() * BorgWorld.PX, level.start_yaw())
	_last_tile = Vector2i(-1, -1)
	scripts.start(world, _player_state())
	_sync_surfaces()
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
		_backdrop_textures = _frame_textures(world.backdrop_frames)
		mat.set_shader_parameter("sky", _backdrop_textures[0])
		mat.set_shader_parameter("sky_size", Vector2(world.backdrop_image.get_size()))
		_backdrop.visible = true
		_env.background_mode = Environment.BG_CANVAS
	else:
		_backdrop.visible = false
		_env.background_mode = Environment.BG_COLOR
	_emblem_textures = _frame_textures(world.emblem_frames)
	_emblem.texture = _emblem_textures[0] if not _emblem_textures.is_empty() else null
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
	_browser.open(pages.to_served(url))
	_browser.visible = true
	_view_container.visible = false
	_address.text = url
	_update_nav_buttons()
	if world == null:
		_maybe_screenshot()


func _close_full_page() -> void:
	if world == null:
		return # nothing to go back to: stay in the browser
	_browser.visible = false
	_view_container.visible = true
	_address.text = BorgUrl.to_display(current_url)
	var title: String = world.level.meta.get("Title", "")
	DisplayServer.window_set_title("%s — OpenQBORG" % title if not title.is_empty() else "OpenQBORG")
	_update_nav_buttons()


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
	print_verbose("page request: ", msg)
	match msg.type:
		"borg":
			open_url(str(msg.url), str(msg.get("base", "")))
		"world":
			var target := pages.to_local(BorgUrl.to_fetchable(str(msg.url), current_url))
			# Pages can announce the same world twice (link + download).
			if _loading and target == _loading_url:
				return
			if target == current_url and world != null:
				_close_full_page()
				return
			_load_world(target, true)
		"web":
			_show_full_page(str(msg.url))
		"moveTile":
			if world != null and _trusted_page(str(msg.get("origin", ""))):
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
	if _browser.visible:
		_update_nav_buttons()
	_update_pointer()
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
	if _backdrop_textures.size() > 1:
		mat.set_shader_parameter("sky", _backdrop_textures[world.backdrop_frames.frame_at(world.anim_ms)])
	if _emblem_textures.size() > 1:
		_emblem.texture = _emblem_textures[world.emblem_frames.frame_at(world.anim_ms)]
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
	# Free look: hold the right mouse button and move.
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if event.pressed else Input.MOUSE_MODE_VISIBLE
		_view_container.grab_focus()
		return
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		walker.look(event.relative)
		return
	if event is InputEventMouseButton and event.pressed and event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
		var wpos: Vector2 = event.position * Vector2(_viewport.size) / _view_container.size
		var wh := world.pick_surface(walker.camera.project_ray_origin(wpos), walker.camera.project_ray_normal(wpos))
		if not wh.is_empty() and _surfaces.has(wh.id):
			_surfaces[wh.id].scroll(wh.uv, event.button_index == MOUSE_BUTTON_WHEEL_UP)
		return
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_view_container.grab_focus()
		var cam := walker.camera
		var pos: Vector2 = event.position * Vector2(_viewport.size) / _view_container.size
		var origin := cam.project_ray_origin(pos)
		var dir := cam.project_ray_normal(pos)
		# A web surface under the pointer gets the click (a video's play button).
		var on_surface := world.pick_surface(origin, dir)
		if not on_surface.is_empty() and _surfaces.has(on_surface.id):
			_surfaces[on_surface.id].click(on_surface.uv)
			return
		# Sprites first: clicking one plays its click behaviour and follows its
		# tile's link, like the original.
		var sprite_tile := world.click(origin, dir)
		if sprite_tile.x >= 0:
			_activate_tile(sprite_tile)
			return
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
	if _shot_started:
		return
	_shot_started = true
	var at := OS.get_environment("OPENQBORG_POS")
	if not at.is_empty() and world != null:
		var xy := at.split(",")
		walker.place(Vector2(float(xy[0]), float(xy[1])), walker.camera.position.y, walker.yaw)
	for i in 240:
		await get_tree().process_frame
	if world == null:
		print("screenshot: browser=%s title=%s address=%s" % [_browser.url(), _browser.page_title(), _address.text])
		get_viewport().get_texture().get_image().save_png(out)
		get_tree().quit()
		return
	print("screenshot: walker=%s yaw=%.3f tile=%s" % [walker.position, walker.yaw, _last_tile])
	print("screenshot: status=%s music=%s page=%s" % [_status.text, music.current, _side_page.current_url])
	var sfx := world.find_children("*", "AudioStreamPlayer3D", true, false).map(func(p): return "%s:%s" % [p.stream.get_class(), p.playing])
	print("screenshot: music_stream=%s sfx=%s" % [music.get_child(1).stream, sfx])
	for sid in _surfaces:
		var simg: Image = _surfaces[sid].get_texture().get_image()
		simg.save_png(out.get_basename() + "_surface_%s.png" % sid)
	print("screenshot: behaviours=%s" % [world._behaviours.map(func(b): return "%s@%s g%d f%d" % [b.sprite.proximity_distance, b.tile, b.group, b.frame])])
	print("screenshot: animated surfaces=%d walls=%d frames(flr)=%s" % [world._surface_anims.size(), world._wall_anims.size(),
			world._floor_frames.images.size() if world._floor_frames else 0])
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
		"setSurface":
			var def: Dictionary = msg.get("def", {})
			def["id"] = str(msg.get("id", "surface"))
			world.set_surface(def)
		"removeSurface":
			world.remove_surface(str(msg.get("id", "")))
		"postToSurface":
			var target: WebSurface = _surfaces.get(str(msg.get("id", "")))
			if target != null:
				target.send_message(msg.get("data"))


## alert()/confirm()/prompt() from world pages, shown by Godot (native JS
## dialogs crash godot-cef).
func _show_page_dialog(text: String) -> void:
	var d := AcceptDialog.new()
	d.title = world.level.meta.get("Title", "OpenQBORG") if world != null else "OpenQBORG"
	d.title = "OpenQBORG" if text.begins_with("OpenQBORG") or text.begins_with("Walk:") else d.title
	d.dialog_text = text
	d.dialog_autowrap = true
	d.min_size = Vector2i(360, 0)
	d.confirmed.connect(d.queue_free)
	d.canceled.connect(d.queue_free)
	add_child(d)
	d.popup_centered()


# --- Menu bar ------------------------------------------------------------------

enum MenuId { OPEN_FILE, OPEN_ADDRESS, RELOAD, BACK, QUIT, ADD_BOOKMARK, REMOVE_BOOKMARK,
		CONTROLS, ABOUT, BOOKMARK_BASE = 1000 }


func _build_menu() -> MenuBar:
	var bar := MenuBar.new()
	bar.prefer_global_menu = false
	var file := PopupMenu.new()
	file.name = "File"
	file.add_item("Open File…", MenuId.OPEN_FILE)
	file.set_item_accelerator(file.get_item_index(MenuId.OPEN_FILE), KEY_MASK_CTRL | KEY_O)
	file.add_item("Open Address…", MenuId.OPEN_ADDRESS)
	file.set_item_accelerator(file.get_item_index(MenuId.OPEN_ADDRESS), KEY_MASK_CTRL | KEY_L)
	file.add_separator()
	file.add_item("Reload", MenuId.RELOAD)
	file.set_item_accelerator(file.get_item_index(MenuId.RELOAD), KEY_F5)
	file.add_item("Back to Previous World", MenuId.BACK)
	file.set_item_accelerator(file.get_item_index(MenuId.BACK), KEY_MASK_ALT | KEY_LEFT)
	file.add_separator()
	file.add_item("Quit", MenuId.QUIT)
	file.set_item_accelerator(file.get_item_index(MenuId.QUIT), KEY_MASK_CTRL | KEY_Q)
	file.id_pressed.connect(_on_menu)
	bar.add_child(file)

	_bookmark_menu = PopupMenu.new()
	_bookmark_menu.name = "Bookmarks"
	_bookmark_menu.id_pressed.connect(_on_menu)
	_bookmark_menu.about_to_popup.connect(_refresh_bookmark_menu)
	bar.add_child(_bookmark_menu)
	bookmarks.load_or_seed()
	bookmarks.changed.connect(_refresh_bookmark_menu)
	_refresh_bookmark_menu()

	var help := PopupMenu.new()
	help.name = "Help"
	help.add_item("Controls", MenuId.CONTROLS)
	help.add_item("About OpenQBORG", MenuId.ABOUT)
	help.id_pressed.connect(_on_menu)
	bar.add_child(help)

	_open_dialog = FileDialog.new()
	_open_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_open_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	_open_dialog.use_native_dialog = true
	_open_dialog.filters = PackedStringArray(["*.borg ; QBORG worlds"])
	_open_dialog.file_selected.connect(func(p: String): open_url(p))
	add_child(_open_dialog)
	return bar


func _refresh_bookmark_menu() -> void:
	var m := _bookmark_menu
	m.clear()
	var marked := bookmarks.index_of(current_url) >= 0
	m.add_item("Bookmark This World", MenuId.ADD_BOOKMARK)
	m.set_item_accelerator(0, KEY_MASK_CTRL | KEY_D)
	m.set_item_disabled(0, current_url.is_empty() or marked)
	m.add_item("Remove This Bookmark", MenuId.REMOVE_BOOKMARK)
	m.set_item_disabled(1, not marked)
	if not bookmarks.items.is_empty():
		m.add_separator()
	for i in bookmarks.items.size():
		var b: Dictionary = bookmarks.items[i]
		m.add_item(b.title, MenuId.BOOKMARK_BASE + i)
		m.set_item_tooltip(m.get_item_count() - 1, BorgUrl.to_display(b.url))


func _on_menu(id: int) -> void:
	match id:
		MenuId.OPEN_FILE:
			_open_dialog.popup_centered_ratio(0.6)
		MenuId.OPEN_ADDRESS:
			_address.grab_focus()
			_address.select_all()
		MenuId.RELOAD:
			_on_reload()
		MenuId.BACK:
			_on_back()
		MenuId.QUIT:
			get_tree().quit()
		MenuId.ADD_BOOKMARK:
			if _browser.visible and not _browser.url().is_empty():
				var page := pages.to_local(_browser.url())
				bookmarks.add(_browser.page_title(), page)
				_status.text = "Bookmarked " + page
			elif world != null:
				bookmarks.add(world.level.meta.get("Title", ""), current_url)
				_status.text = "Bookmarked " + BorgUrl.to_display(current_url)
		MenuId.REMOVE_BOOKMARK:
			bookmarks.remove(current_url)
		MenuId.CONTROLS:
			_show_page_dialog("Walk: ↑ ↓ or W S     Turn: ← →     Strafe: A D\nLook up/down: PgUp PgDn\n"
					+ "Click a tile (or the nav map) to follow its link.")
		MenuId.ABOUT:
			_show_page_dialog("OpenQBORG Player\nAn open source player for CYBERWORLD QBORG worlds.\n\n"
					+ "Free software under the GNU GPL v3 or later.\nhttps://github.com/kramlat/OpenQBORG\n\n"
					+ "Page engine: %s\nExtra audio formats: %s" % [
						"godot-cef (Chromium)" if HtmlView.cef_available() else "not installed",
						"FFmpeg " + ClassDB.class_call_static("FFmpegAudioDecoder", "ffmpeg_version")
								if BorgAudio.has_ffmpeg() else "not installed"])
		_:
			if id >= MenuId.BOOKMARK_BASE and id - MenuId.BOOKMARK_BASE < bookmarks.items.size():
				open_url(bookmarks.items[id - MenuId.BOOKMARK_BASE].url)


func _shortcut_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	var k := event as InputEventKey
	var id := -1
	if k.ctrl_pressed and k.keycode == KEY_O:
		id = MenuId.OPEN_FILE
	elif k.ctrl_pressed and k.keycode == KEY_L:
		id = MenuId.OPEN_ADDRESS
	elif k.ctrl_pressed and k.keycode == KEY_D:
		id = MenuId.ADD_BOOKMARK
	elif k.ctrl_pressed and k.keycode == KEY_Q:
		id = MenuId.QUIT
	elif k.keycode == KEY_F5:
		id = MenuId.RELOAD
	elif k.alt_pressed and k.keycode == KEY_LEFT:
		id = MenuId.BACK
	if id >= 0:
		_on_menu(id)
		get_viewport().set_input_as_handled()


# --- Built-in browser --------------------------------------------------------------

## Back steps through web history first, then leaves the browser, then goes
## to the previous world.
func _on_back() -> void:
	if _browser.visible and _browser.can_go_back():
		_browser.go_back()
	elif _browser.visible and world != null:
		_close_full_page()
	else:
		go_back()


func _on_reload() -> void:
	if _browser.visible:
		_browser.reload()
	elif not current_url.is_empty():
		_load_world(current_url, false)


func _update_nav_buttons() -> void:
	var in_browser := _browser.visible
	_back.disabled = not (history.size() > 0 or (in_browser and (_browser.can_go_back() or world != null)))
	_forward.disabled = not (in_browser and _browser.can_go_forward())


func _on_browser_address(url: String) -> void:
	if _browser.visible and not _address.has_focus():
		_address.text = pages.to_local(url)
	_update_nav_buttons()


func _on_browser_title(title: String) -> void:
	if _browser.visible:
		DisplayServer.window_set_title("%s — OpenQBORG" % title if not title.is_empty() else "OpenQBORG")


## Only the current world's own pages may change the world through
## window.external: pages served for it locally, or from its own site.
func _trusted_page(origin: String) -> bool:
	if world == null or origin.is_empty():
		return false
	if pages.is_running() and origin.begins_with(pages.origin() + "/"):
		return true
	return _site_of(origin) == _site_of(world.base_url)


static func _site_of(url: String) -> String:
	var i := url.find("://")
	if i < 0:
		return ""
	var end := url.find("/", i + 3)
	return (url if end < 0 else url.left(end)).to_lower()


static func _frame_textures(frames: BorgFrames) -> Array[Texture2D]:
	var out: Array[Texture2D] = []
	if frames != null:
		for img in frames.images:
			out.append(ImageTexture.create_from_image(img))
	return out


## Feeds the mouse ray to the world (mouse-over behaviours) and shows a
## pointing hand over anything clickable: interactive sprites and linked tiles.
func _update_pointer() -> void:
	if world == null or _loading:
		return
	var local := _view_container.get_local_mouse_position()
	var inside := _view_container.visible and Rect2(Vector2.ZERO, _view_container.size).has_point(local) \
			and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED
	var cam := walker.camera
	var pos := local * Vector2(_viewport.size) / _view_container.size
	world.set_pointer(cam.project_ray_origin(pos), cam.project_ray_normal(pos), inside)
	var clickable := false
	if inside:
		var on_surface := world.pick_surface(cam.project_ray_origin(pos), cam.project_ray_normal(pos))
		if not on_surface.is_empty() and _surfaces.has(on_surface.id):
			_surfaces[on_surface.id].pointer_move(on_surface.uv)
			clickable = true
		var hovered: Dictionary = world.hovered_sprite
		if clickable:
			pass
		elif not hovered.is_empty():
			var b: SpriteBehaviour = hovered.get("behaviour")
			clickable = (b != null and b.reacts_to_mouse()) or _tile_has_link(hovered.tile)
		else:
			var dir := cam.project_ray_normal(pos)
			if dir.y < -0.001:
				var origin := cam.project_ray_origin(pos)
				clickable = _tile_has_link(world.tile_of(origin + dir * (-origin.y / dir.y)))
	_view_container.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND if clickable else Control.CURSOR_ARROW


func _tile_has_link(t: Vector2i) -> bool:
	return world.in_bounds(t) and (world.level.get_cell("gtw", t.x, t.y) > 0 or world.level.get_cell("gtw2", t.x, t.y) > 0
			or world.level.get_cell("js", t.x, t.y) > 0)


# --- Web surfaces ---------------------------------------------------------------------

## Matches live pages to the world's surfaces: keeps pages whose address and
## size are unchanged (so a video keeps playing through rebuilds), makes new
## ones, drops the rest, and puts each page's texture on its surface.
func _sync_surfaces() -> void:
	if world == null or not HtmlView.cef_available():
		return
	var live := {}
	for id in world.surface_nodes:
		var s: Dictionary = world.surface_nodes[id]
		# Script-made HTML5 screens are served by the page server.
		var url := pages.set_inline_page(id, str(s.def.html), world.base_url) if s.def.has("html") \
				else _surface_url(str(s.def.url))
		var ws: WebSurface = _surfaces.get(id)
		if ws != null and (ws.url != url or ws.size != s.texture_size):
			ws.queue_free()
			ws = null
		if ws == null:
			ws = WebSurface.new(url, s.texture_size)
			ws.surface_id = id
			ws.page_request.connect(_on_surface_request)
			add_child(ws)
		var mat: StandardMaterial3D = s.material
		mat.albedo_texture = ws.get_texture()
		mat.albedo_color = Color.WHITE
		var c: Array[Vector3] = s.corners
		ws.place_audio(_viewport, (c[0] + c[2]) * 0.5 + s.normal * 0.2, c[0].distance_to(c[1]))
		live[id] = ws
	for id in _surfaces:
		if not live.has(id):
			_surfaces[id].queue_free()
	_surfaces = live


func _clear_surfaces() -> void:
	for id in _surfaces:
		_surfaces[id].queue_free()
	_surfaces = {}


## Surface addresses are relative to the world; local files go through the
## page server, and .swf files get a Ruffle page.
func _surface_url(raw: String) -> String:
	var url := raw if raw.contains("://") or raw.begins_with("about:") or raw.begins_with("data:") \
			else BorgUrl.join(world.base_url, raw)
	url = pages.to_served(url)
	if url.get_slice("?", 0).to_lower().ends_with(".swf") and pages.is_running():
		url = pages.helper_page("swf.html") + "?src=" + url.uri_encode()
	return url


## Requests from a surface's page: messages for the world script, or the
## usual page requests (borg:// links, dialogs...).
func _on_surface_request(msg: Dictionary) -> void:
	if msg.type == "surfaceMessage":
		scripts.send_surface_message(str(msg.surface), msg.get("data"))
	else:
		_on_page_request(msg)
