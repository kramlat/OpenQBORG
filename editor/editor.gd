# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 Mark Toman and OpenQBORG contributors
extends Control
## OpenQBORG Editor: an open source take on CYBERWORLD's QBORG authoring tool.
##
## The world is edited live in 3D: pick a layer and a value, then paint
## tiles with the left mouse button. Ctrl+click picks a tile's value.
## Right-drag orbits, middle-drag (or Shift+right-drag) pans, wheel zooms.
## "Walk" drops you into the world with the player's controls (Esc leaves).

const LAYERS := [
	["wal", "No-walk / wall texture"], ["hgt", "Wall height"], ["flr", "Floor"],
	["cei", "Ceiling"], ["obj", "Objects"], ["gtw", "Doorways (gtw)"],
	["gtw2", "Info pages (gtw2)"], ["wav", "Sounds"], ["mid", "Music"],
	["js", "Script triggers"], ["@start", "Start position"],
]
## Layers you can't see in 3D get a colour overlay while selected.
const OVERLAY_LAYERS := ["wal", "gtw", "gtw2", "wav", "mid", "js"]
## <ext> lists in the Resources panel: [tag, label, folder].
const RESOURCE_LISTS := [
	["spr", "Sprites", "objects"], ["gtw", "Doorway links", "domains"],
	["gtw2", "Info page links", "domains"], ["gtw3", "Default page", "domains"],
	["wav", "Sounds", "media"], ["mid", "Music", "media"], ["js", "Scripts", "scripts"],
	["nav", "Nav map", "domains"], ["emb", "Emblem", "domains"],
]
## Tiled texture references: [tag, label, tile width in px].
const TEXTURE_REFS := [["flr", "Floor tiles", 256], ["cei", "Ceiling tiles", 256], ["wal", "Wall strips", 1024]]

var level: BorgLevel
var path := ""
var world: BorgWorld
var fetcher := BorgFetcher.new()
var music := BorgMusic.new()
var undo := UndoRedo.new()
var library := StarterLibrary.new()

var _unsaved := false
var _geometry_dirty := false
var _painting := false
var _stroke_layer := ""
var _stroke_before := PackedByteArray()
var _hover := Vector2i(-1, -1)
var _building := false

var _viewport: SubViewport
var _view_container: SubViewportContainer
var _camera: OrbitCamera
var _overlay: TileOverlay
var _env: Environment
var _walker: BorgWalker
var _center_tabs: TabContainer
var _layer_list: ItemList
var _value_list: ItemList
var _value_spin: SpinBox
var _status: Label
var _file_dialog: FileDialog
var _props := {}
var _res_kind: OptionButton
var _res_list: ItemList
var _res_edit: LineEdit
var _res_play: Button
var _res_script: Button
var _tex_edits := {}
var _tex_counts := {}
var _code: CodeEdit
var _code_path := ""
var _code_label: Label


func _ready() -> void:
	DisplayServer.window_set_min_size(Vector2i(960, 600))
	add_child(fetcher)
	add_child(music)
	music.status_changed.connect(func(t): _status.text = t)
	library.load_library()
	_build_ui()
	var start := ""
	for arg in OS.get_cmdline_user_args():
		if arg.to_lower().ends_with(".borg"):
			start = arg
	if start.is_empty():
		new_level()
	else:
		open_file(start)


# --- UI ----------------------------------------------------------------------

func _build_ui() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(root)

	var bar := HBoxContainer.new()
	root.add_child(bar)
	for spec in [["New", new_level], ["Open…", _ask_open], ["Save", save], ["Save As…", _ask_save_as],
			["Undo", undo.undo], ["Redo", undo.redo], ["Walk", _toggle_walk],
			["Play in Player", _play_in_player]]:
		var b := Button.new()
		b.text = spec[0]
		b.pressed.connect(spec[1])
		bar.add_child(b)

	var split := HSplitContainer.new()
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(split)
	split.add_child(_build_left_dock())
	var inner := HSplitContainer.new()
	inner.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	split.add_child(inner)

	_center_tabs = TabContainer.new()
	_center_tabs.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	inner.add_child(_center_tabs)
	_view_container = SubViewportContainer.new()
	_view_container.name = "World"
	_view_container.stretch = true
	_view_container.focus_mode = Control.FOCUS_CLICK
	_view_container.gui_input.connect(_on_view_input)
	_center_tabs.add_child(_view_container)
	_viewport = SubViewport.new()
	_viewport.handle_input_locally = false
	_view_container.add_child(_viewport)
	_setup_scene()
	_center_tabs.add_child(_build_script_tab())
	_center_tabs.add_child(_build_library_tab())

	inner.add_child(_build_right_dock())

	_status = Label.new()
	_status.clip_text = true
	root.add_child(_status)

	_file_dialog = FileDialog.new()
	_file_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_file_dialog.use_native_dialog = true
	_file_dialog.filters = PackedStringArray(["*.borg ; QBORG worlds"])
	add_child(_file_dialog)


func _build_left_dock() -> Control:
	var dock := VBoxContainer.new()
	dock.custom_minimum_size.x = 220
	dock.add_child(_heading("Layer"))
	_layer_list = ItemList.new()
	_layer_list.custom_minimum_size.y = 260
	for l in LAYERS:
		_layer_list.add_item(l[1])
	_layer_list.item_selected.connect(func(_i): _refresh_values(); _refresh_overlay())
	dock.add_child(_layer_list)
	dock.add_child(_heading("Value"))
	_value_spin = SpinBox.new()
	_value_spin.max_value = 255
	dock.add_child(_value_spin)
	_value_list = ItemList.new()
	_value_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_value_list.fixed_icon_size = Vector2i(32, 32)
	_value_list.item_selected.connect(func(i): _value_spin.value = _value_list.get_item_metadata(i))
	dock.add_child(_value_list)
	return dock


func _build_right_dock() -> Control:
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size.x = 320
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var dock := VBoxContainer.new()
	dock.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(dock)

	dock.add_child(_heading("World"))
	var grid := GridContainer.new()
	grid.columns = 2
	dock.add_child(grid)
	_prop_line(grid, "title", "Title")
	_prop_line(grid, "rights", "Rights")
	_prop_spin(grid, "width", "Width (tiles)", BorgLevel.CLASSIC_SIZE, BorgLevel.MAX_SIZE, false)
	_prop_spin(grid, "height", "Height (tiles)", BorgLevel.CLASSIC_SIZE, BorgLevel.MAX_SIZE, false)
	var resize := Button.new()
	resize.text = "Apply size"
	resize.pressed.connect(_apply_size)
	grid.add_child(Control.new())
	grid.add_child(resize)
	_prop_spin(grid, "ceiling", "Ceiling height (px)", 4, 1020, true)
	_prop_spin(grid, "speed", "Walk speed (SP)", 1, 1000, true)
	_prop_spin(grid, "angle", "Start facing (°)", 0, 359, true)
	_prop_spin(grid, "eye", "Eye height (px)", 0, 1020, true)
	_prop_spin(grid, "pos", "Backdrop offset (px)", -2000, 2000, true)
	grid.add_child(_label("Background"))
	var color := ColorPickerButton.new()
	color.custom_minimum_size = Vector2(80, 24)
	color.color_changed.connect(func(c): level.set_background_color(c); _env.background_color = c; _mark_unsaved())
	grid.add_child(color)
	_props["color"] = color
	grid.add_child(_label("Backdrop image"))
	var bck := LineEdit.new()
	bck.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bck.text_submitted.connect(_set_backdrop_image)
	grid.add_child(bck)
	_props["backdrop"] = bck

	dock.add_child(_heading("Textures (domains/)"))
	var tex_grid := GridContainer.new()
	tex_grid.columns = 3
	dock.add_child(tex_grid)
	for t in TEXTURE_REFS:
		tex_grid.add_child(_label(t[1]))
		var e := LineEdit.new()
		e.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		e.tooltip_text = "Image file in domains/; Enter to apply (tiles are detected automatically)"
		e.text_submitted.connect(func(text): _set_texture_ref(t[0], text, int(t[2])))
		tex_grid.add_child(e)
		_tex_edits[t[0]] = e
		var count := Label.new()
		tex_grid.add_child(count)
		_tex_counts[t[0]] = count

	dock.add_child(_heading("Resources"))
	_res_kind = OptionButton.new()
	for r in RESOURCE_LISTS:
		_res_kind.add_item("%s (%s/)" % [r[1], r[2]])
	_res_kind.item_selected.connect(func(_i): _refresh_resources())
	dock.add_child(_res_kind)
	_res_list = ItemList.new()
	_res_list.custom_minimum_size.y = 160
	dock.add_child(_res_list)
	var row := HBoxContainer.new()
	dock.add_child(row)
	_res_edit = LineEdit.new()
	_res_edit.placeholder_text = "file name"
	_res_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_res_edit.text_submitted.connect(func(_t): _res_add())
	row.add_child(_res_edit)
	var buttons := HBoxContainer.new()
	dock.add_child(buttons)
	for spec in [["Add", _res_add], ["Remove", _res_remove], ["↑", _res_move.bind(-1)], ["↓", _res_move.bind(1)]]:
		var b := Button.new()
		b.text = spec[0]
		b.pressed.connect(spec[1])
		buttons.add_child(b)
	_res_play = Button.new()
	_res_play.text = "▶ Play"
	_res_play.pressed.connect(_res_toggle_music)
	buttons.add_child(_res_play)
	_res_script = Button.new()
	_res_script.text = "Edit script"
	_res_script.pressed.connect(_res_edit_script)
	buttons.add_child(_res_script)
	return scroll


func _build_script_tab() -> Control:
	var box := VBoxContainer.new()
	box.name = "Script"
	var row := HBoxContainer.new()
	box.add_child(row)
	_code_label = Label.new()
	_code_label.text = "No script open. Add one under Resources → Scripts, then Edit script."
	_code_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(_code_label)
	var save_btn := Button.new()
	save_btn.text = "Save script"
	save_btn.pressed.connect(_save_script)
	row.add_child(save_btn)
	_code = CodeEdit.new()
	_code.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_code.gutters_draw_line_numbers = true
	_code.indent_automatic = true
	_code.auto_brace_completion_enabled = true
	_code.syntax_highlighter = _js_highlighter()
	box.add_child(_code)
	return box


static func _js_highlighter() -> CodeHighlighter:
	var h := CodeHighlighter.new()
	h.number_color = Color("#b5cea8")
	h.symbol_color = Color("#d4d4d4")
	h.function_color = Color("#dcdcaa")
	h.member_variable_color = Color("#9cdcfe")
	for kw in ["var", "let", "const", "function", "return", "if", "else", "for", "while", "do",
			"switch", "case", "break", "continue", "new", "this", "typeof", "instanceof", "in", "of",
			"true", "false", "null", "undefined", "class", "extends", "try", "catch", "finally",
			"throw", "async", "await", "yield", "delete", "default"]:
		h.add_keyword_color(kw, Color("#569cd6"))
	h.add_member_keyword_color("borg", Color("#4ec9b0"))
	h.add_color_region('"', '"', Color("#ce9178"))
	h.add_color_region("'", "'", Color("#ce9178"))
	h.add_color_region("`", "`", Color("#ce9178"))
	h.add_color_region("//", "", Color("#6a9955"), true)
	h.add_color_region("/*", "*/", Color("#6a9955"))
	return h


func _setup_scene() -> void:
	_env = Environment.new()
	_env.background_mode = Environment.BG_COLOR
	var we := WorldEnvironment.new()
	we.environment = _env
	_viewport.add_child(we)
	_camera = OrbitCamera.new()
	_viewport.add_child(_camera)
	_overlay = TileOverlay.new()
	_viewport.add_child(_overlay)


static func _heading(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 15)
	return l


static func _label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	return l


func _prop_line(grid: GridContainer, key: String, label: String) -> void:
	grid.add_child(_label(label))
	var e := LineEdit.new()
	e.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	e.text_changed.connect(func(_t): _props_to_level())
	grid.add_child(e)
	_props[key] = e


func _prop_spin(grid: GridContainer, key: String, label: String, lo: float, hi: float, live: bool) -> void:
	grid.add_child(_label(label))
	var s := SpinBox.new()
	s.min_value = lo
	s.max_value = hi
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if live:
		s.value_changed.connect(func(_v): _props_to_level())
	grid.add_child(s)
	_props[key] = s


# --- Files -------------------------------------------------------------------

func new_level() -> void:
	var l := BorgLevel.create_empty()
	if library.available():
		library.furnish(l)
	_load_level(l, "")


func open_file(p: String) -> void:
	var l := BorgLevel.load_file(p)
	if l == null:
		_status.text = "Could not open " + p
		return
	_load_level(l, p)


func save() -> void:
	if path.is_empty():
		_ask_save_as()
		return
	var err := level.save_file(path)
	if err != OK:
		_status.text = "Save failed: %s" % error_string(err)
		return
	_unsaved = false
	_update_title()
	_status.text = "Saved " + path
	if library.available():
		var copied := library.copy_used(level, path.get_base_dir())
		if not copied.is_empty():
			_status.text += "  (copied %d file(s) from the starter library)" % copied.size()


func _ask_open() -> void:
	_file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	_disconnect_dialog()
	_file_dialog.file_selected.connect(open_file, CONNECT_ONE_SHOT)
	_file_dialog.popup_centered_ratio(0.6)


func _ask_save_as() -> void:
	_file_dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	_disconnect_dialog()
	_file_dialog.file_selected.connect(func(p: String):
		path = p if p.to_lower().ends_with(".borg") else p + ".borg"
		save()
		_reload_world(), CONNECT_ONE_SHOT)
	_file_dialog.popup_centered_ratio(0.6)


func _disconnect_dialog() -> void:
	for c in _file_dialog.file_selected.get_connections():
		_file_dialog.file_selected.disconnect(c.callable)


func _load_level(l: BorgLevel, p: String) -> void:
	level = l
	path = p
	undo.clear_history()
	_unsaved = false
	_level_to_props()
	_layer_list.select(0)
	_refresh_values()
	_refresh_resources()
	_update_title()
	await _reload_world()
	_camera.frame_world(level.width, level.height)
	_maybe_screenshot()


## Rebuilds the 3D world, refetching assets from the .borg's folders.
func _reload_world() -> void:
	if _building:
		return
	_building = true
	fetcher.clear_cache()
	# Unsaved worlds preview straight from the starter library.
	var url := "file://" + path if not path.is_empty() \
			else (library.base_url() + "unsaved.borg" if library.available() else "file:///nonexistent/unsaved.borg")
	var next := BorgWorld.new()
	await next.build(level, url, fetcher)
	if world != null:
		world.queue_free()
	world = next
	_viewport.add_child(world)
	_env.background_color = level.background_color()
	_overlay.set_grid(level.width, level.height)
	_refresh_overlay()
	_refresh_values()
	_building = false
	if path.is_empty():
		_status.text = "New world. Add things from the Library tab; what you use is copied next to the world when you save."


func _update_title() -> void:
	var name := path.get_file() if not path.is_empty() else "untitled.borg"
	DisplayServer.window_set_title("%s%s — OpenQBORG Editor" % [name, "*" if _unsaved else ""])


func _mark_unsaved() -> void:
	if not _unsaved:
		_unsaved = true
		_update_title()


func _play_in_player() -> void:
	if _unsaved or path.is_empty():
		save()
		if path.is_empty():
			return
	# Development checkout: run the sibling Godot project with this engine.
	var player_dir := ProjectSettings.globalize_path("res://").path_join("../player").simplify_path()
	var args: PackedStringArray
	var exe := OS.get_executable_path()
	if FileAccess.file_exists(player_dir.path_join("project.godot")):
		args = ["--path", player_dir, "--", path]
	else:
		# Exported builds ship openqborg-player next to the editor.
		exe = exe.get_base_dir().path_join("openqborg-player" + (".exe" if OS.get_name() == "Windows" else ""))
		args = [path]
	OS.create_process(exe, args)


# --- Properties --------------------------------------------------------------

func _level_to_props() -> void:
	var updating := _props.duplicate()
	_props.clear() # suppress _props_to_level while filling
	updating.title.text = level.meta.get("Title", "")
	updating.rights.text = level.meta.get("Rights", "")
	updating.width.value = level.width
	updating.height.value = level.height
	updating.ceiling.value = level.ceiling_height_px()
	updating.speed.value = level.speed()
	updating.angle.value = fposmod(rad_to_deg(level.start_yaw()), 360.0)
	updating.eye.value = level.start_eye_height_px()
	updating.pos.value = level.backdrop_offset()
	updating.color.color = level.background_color()
	var bdp := level.find_ext("bdp")
	var bck := ""
	for item in bdp.get("items", []):
		if item.kind == "file":
			bck = item.href
	updating.backdrop.text = bck
	for t in TEXTURE_REFS:
		var cfil := level.ext_cfil(t[0])
		_tex_edits[t[0]].text = cfil.get("href", "")
		_tex_counts[t[0]].text = "%d" % cfil.get("offsets", []).size() if not cfil.is_empty() else ""
	_props = updating
	_overlay.set_start(level.start_tile_position(), level.start_yaw())


func _props_to_level() -> void:
	if _props.is_empty() or level == null:
		return
	level.meta["Title"] = _props.title.text
	level.meta["Rights"] = _props.rights.text
	var old_height := level.ceiling_height_px()
	level.set_ceiling_height_px(_props.ceiling.value)
	level.set_speed(int(_props.speed.value))
	level.set_start_yaw(deg_to_rad(_props.angle.value))
	level.start_pos[2] = int(_props.eye.value / 4.0)
	level.set_backdrop_offset(int(_props.pos.value))
	_overlay.set_start(level.start_tile_position(), level.start_yaw())
	if old_height != level.ceiling_height_px() and world != null:
		world.ceiling_height = level.ceiling_height_px() * BorgWorld.PX
		_geometry_dirty = true
	_mark_unsaved()


func _apply_size() -> void:
	var before := level.serialize()
	level.resize(int(_props.width.value), int(_props.height.value))
	var after := level.serialize()
	undo.create_action("Resize world")
	undo.add_do_method(_restore_snapshot.bind(after))
	undo.add_undo_method(_restore_snapshot.bind(before))
	undo.commit_action(false)
	_mark_unsaved()
	_reload_world()
	_camera.frame_world(level.width, level.height)


func _restore_snapshot(text: String) -> void:
	var keep_path := path
	var l := BorgLevel.parse(text)
	level = l
	path = keep_path
	_level_to_props()
	_mark_unsaved()
	_reload_world()


func _set_backdrop_image(href: String) -> void:
	var bdp := level.ensure_ext("bdp")
	bdp.items = bdp.items.filter(func(i): return i.kind != "file")
	if not href.strip_edges().is_empty():
		bdp.items.append({"kind": "file", "href": href.strip_edges(), "text": ""})
	_mark_unsaved()
	_reload_world()


## Points a floor/ceiling/wall reference at an image and derives the tile
## offsets from its size: floors/ceilings are 256x256 cells, walls are
## 256-pixel-tall strips of a 1024-wide image.
func _set_texture_ref(tag: String, href: String, tile_w: int) -> void:
	href = href.strip_edges()
	var offsets := PackedInt64Array()
	if not href.is_empty() and not path.is_empty():
		var file := BorgUrl.resolve_case(path.get_base_dir().path_join("domains").path_join(href))
		var img := BorgWorld.decode_image(FileAccess.get_file_as_bytes(file))
		if img == null:
			_status.text = "Can't read domains/" + href
			return
		var w := img.get_width()
		for row in img.get_height() / 256:
			for col in maxi(1, w / tile_w):
				offsets.append(row * 256 * w + col * tile_w)
	level.set_ext_cfil(tag, href, offsets)
	_tex_counts[tag].text = "%d" % offsets.size() if not href.is_empty() else ""
	_mark_unsaved()
	_reload_world()


# --- Layers and values -------------------------------------------------------

func _current_layer() -> String:
	var sel := _layer_list.get_selected_items()
	return LAYERS[sel[0]][0] if sel.size() > 0 else "wal"


static func _empty_value(layer: String) -> int:
	return BorgLevel.EMPTY_SURFACE if layer in BorgLevel.SURFACE_LAYERS else 0


func _refresh_values() -> void:
	if level == null:
		return
	_value_list.clear()
	var layer := _current_layer()
	var add := func(label: String, value: int, icon: Texture2D = null):
		var i := _value_list.add_item(label, icon)
		_value_list.set_item_metadata(i, value)
	match layer:
		"@start":
			_value_list.add_item("Click in the world to set the start")
			_value_list.set_item_disabled(0, true)
		"flr", "cei":
			add.call("(none)", BorgLevel.EMPTY_SURFACE)
			var count: int = level.ext_cfil(layer).get("offsets", []).size()
			for i in count:
				add.call("Tile %d" % i, i)
		"wal":
			add.call("(walkable)", 0)
			var strips: int = level.ext_cfil("wal").get("offsets", []).size()
			for i in maxi(1, strips):
				add.call("Blocked / texture %d" % (i + 1), i + 1)
		"hgt":
			add.call("(flat)", 0)
			for px in [64, 128, 256, 512, 1020]:
				add.call("%d px" % px, px / 4)
		"obj":
			add.call("(none)", 0)
			var sprites := level.ext_files("spr")
			for i in sprites.size():
				add.call("%d  %s" % [i + 1, sprites[i]], i + 1)
		"js":
			add.call("(none)", 0)
			for i in range(1, 17):
				add.call("Trigger %d" % i, i, _swatch(TileOverlay.value_color(i)))
		_:
			add.call("(none)", 0)
			var files := level.ext_files(layer)
			for i in files.size():
				add.call("%d  %s" % [i + 1, files[i]], i + 1, _swatch(TileOverlay.value_color(i + 1)))
	_value_spin.value = _empty_value(layer) if layer != "wal" and layer != "hgt" else (1 if layer == "wal" else 64)


static func _swatch(c: Color) -> Texture2D:
	var img := Image.create(16, 16, false, Image.FORMAT_RGBA8)
	img.fill(Color(c, 1.0))
	return ImageTexture.create_from_image(img)


func _refresh_overlay() -> void:
	if level == null:
		return
	var layer := _current_layer()
	_overlay.show_layer(level, layer if layer in OVERLAY_LAYERS else "", _empty_value(layer))


# --- Painting ----------------------------------------------------------------

func _on_view_input(event: InputEvent) -> void:
	if level == null:
		return
	if _walker != null:
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if event.pressed else Input.MOUSE_MODE_VISIBLE
		elif event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
			_walker.look(event.relative)
		if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
			_toggle_walk()
		return
	if _camera.handle_input(event):
		return
	if event is InputEventMouseMotion:
		var hit := _pick(event.position)
		var tile := Vector2i(floori(hit.x), floori(hit.z)) if hit != Vector3.INF else Vector2i(-1, -1)
		if tile != _hover:
			_hover = tile
			_overlay.set_cursor(tile, level.in_bounds(tile.x, tile.y))
			_show_tile_status(tile)
		if _painting and (event.button_mask & MOUSE_BUTTON_MASK_LEFT):
			_paint(tile)
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		var hit := _pick(event.position)
		if hit == Vector3.INF:
			return
		var tile := Vector2i(floori(hit.x), floori(hit.z))
		var layer := _current_layer()
		if event.pressed:
			if layer == "@start":
				_set_start(Vector2(hit.x, hit.z))
			elif event.ctrl_pressed:
				_value_spin.value = level.get_cell(layer, tile.x, tile.y)
			else:
				_begin_stroke(layer)
				_paint(tile)
		elif _painting:
			_end_stroke()


func _pick(screen_pos: Vector2) -> Vector3:
	var pos := screen_pos * Vector2(_viewport.size) / _view_container.size
	var origin := _camera.project_ray_origin(pos)
	var dir := _camera.project_ray_normal(pos)
	if dir.y > -0.0001:
		return Vector3.INF
	return origin + dir * (-origin.y / dir.y)


func _begin_stroke(layer: String) -> void:
	if not level.layers.has(layer):
		level.set_cell(layer, 0, 0, _empty_value(layer)) # creates the layer
	_painting = true
	_stroke_layer = layer
	_stroke_before = level.layers[layer].duplicate()


func _paint(tile: Vector2i) -> void:
	if not level.in_bounds(tile.x, tile.y):
		return
	var v := int(_value_spin.value)
	if level.get_cell(_stroke_layer, tile.x, tile.y) == v:
		return
	level.set_cell(_stroke_layer, tile.x, tile.y, v)
	_geometry_dirty = true
	_mark_unsaved()
	_show_tile_status(tile)


func _end_stroke() -> void:
	_painting = false
	var after: PackedByteArray = level.layers[_stroke_layer].duplicate()
	if after == _stroke_before:
		return
	undo.create_action("Paint " + _stroke_layer)
	undo.add_do_method(_set_grid.bind(_stroke_layer, after))
	undo.add_undo_method(_set_grid.bind(_stroke_layer, _stroke_before))
	undo.commit_action(false)


func _set_grid(layer: String, grid: PackedByteArray) -> void:
	if grid.size() != level.tile_count():
		return # the world was resized since
	level.layers[layer] = grid.duplicate()
	_geometry_dirty = true
	_mark_unsaved()


func _set_start(p: Vector2) -> void:
	var before := level.start_pos.duplicate()
	level.set_start_tile_position(p)
	var after := level.start_pos.duplicate()
	undo.create_action("Move start")
	undo.add_do_method(_set_start_raw.bind(after))
	undo.add_undo_method(_set_start_raw.bind(before))
	undo.commit_action()


func _set_start_raw(raw: PackedInt32Array) -> void:
	level.start_pos = raw.duplicate()
	_overlay.set_start(level.start_tile_position(), level.start_yaw())
	_mark_unsaved()


func _show_tile_status(tile: Vector2i) -> void:
	if not level.in_bounds(tile.x, tile.y):
		_status.text = "%d×%d world" % [level.width, level.height]
		return
	var parts := PackedStringArray()
	for l in LAYERS:
		if l[0] != "@start" and level.layers.has(l[0]):
			parts.append("%s=%d" % [l[0], level.get_cell(l[0], tile.x, tile.y)])
	_status.text = "(%d, %d)   %s" % [tile.x, tile.y, "  ".join(parts)]


func _process(_delta: float) -> void:
	if _geometry_dirty and world != null and not _building:
		_geometry_dirty = false
		world.rebuild()
		_refresh_overlay()


func _shortcut_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and event.ctrl_pressed):
		return
	match event.keycode:
		KEY_S:
			save()
		KEY_O:
			_ask_open()
		KEY_N:
			new_level()
		KEY_Z:
			if event.shift_pressed:
				undo.redo()
			else:
				undo.undo()
		KEY_Y:
			undo.redo()
		_:
			return
	get_viewport().set_input_as_handled()


# --- Walk preview ------------------------------------------------------------

func _toggle_walk() -> void:
	if _walker != null:
		_walker.queue_free()
		_walker = null
		_camera.make_current()
		_overlay.visible = true
		_status.text = "Editing"
		return
	_walker = BorgWalker.new()
	_viewport.add_child(_walker)
	_walker.walk_speed = maxf(1.0, level.speed() / 150.0 * 4.0)
	_walker.place(level.start_tile_position(), level.start_eye_height_px() * BorgWorld.PX, level.start_yaw())
	_walker.camera.make_current()
	if world != null:
		world.viewer = _walker.camera
	_overlay.visible = false
	_view_container.grab_focus()
	_status.text = "Walking — arrows/WASD, PgUp/PgDn to look, Esc to stop"


# --- Resources ---------------------------------------------------------------

func _res_tag() -> String:
	return RESOURCE_LISTS[maxi(0, _res_kind.selected)][0]


func _refresh_resources() -> void:
	if level == null:
		return
	_res_list.clear()
	for f in level.ext_files(_res_tag()):
		_res_list.add_item(f)
	_res_play.visible = _res_tag() == "mid"
	_res_script.visible = _res_tag() == "js"


func _res_set(files: PackedStringArray) -> void:
	var tag := _res_tag()
	var before := level.ext_files(tag)
	level.set_ext_files(tag, files)
	undo.create_action("Edit " + tag)
	undo.add_do_method(_res_apply.bind(tag, files))
	undo.add_undo_method(_res_apply.bind(tag, before))
	undo.commit_action(false)
	_res_apply(tag, files)


func _res_apply(tag: String, files: PackedStringArray) -> void:
	level.set_ext_files(tag, files)
	_refresh_resources()
	_refresh_values()
	_mark_unsaved()
	if tag in ["spr", "wav", "nav", "emb", "js"]:
		_reload_world()


func _res_add() -> void:
	var name := _res_edit.text.strip_edges()
	if name.is_empty():
		return
	var files := level.ext_files(_res_tag())
	if _res_tag() in ["gtw3", "nav", "emb"]:
		files = PackedStringArray() # single-file entries
	files.append(name)
	_res_edit.clear()
	_res_set(files)


func _res_remove() -> void:
	var sel := _res_list.get_selected_items()
	if sel.is_empty():
		return
	var files := level.ext_files(_res_tag())
	files.remove_at(sel[0])
	_res_set(files)


func _res_move(delta: int) -> void:
	var sel := _res_list.get_selected_items()
	if sel.is_empty():
		return
	var files := level.ext_files(_res_tag())
	var i: int = sel[0]
	var j := i + delta
	if j < 0 or j >= files.size():
		return
	var tmp := files[i]
	files[i] = files[j]
	files[j] = tmp
	_res_set(files)
	_res_list.select(j)


func _res_toggle_music() -> void:
	if not music.current.is_empty():
		music.play_url("", fetcher)
		_res_play.text = "▶ Play"
		return
	var sel := _res_list.get_selected_items()
	if sel.is_empty() or path.is_empty():
		return
	var url := BorgUrl.join("file://" + path.get_base_dir() + "/", "media/" + _res_list.get_item_text(sel[0]))
	music.play_url(url, fetcher)
	_res_play.text = "■ Stop"


func _res_edit_script() -> void:
	var sel := _res_list.get_selected_items()
	if sel.is_empty():
		return
	if path.is_empty():
		_status.text = "Save the world first; scripts live in its scripts/ folder."
		return
	_code_path = path.get_base_dir().path_join("scripts").path_join(_res_list.get_item_text(sel[0]))
	var existing := BorgUrl.resolve_case(_code_path)
	_code.text = FileAccess.get_file_as_string(existing) if FileAccess.file_exists(existing) else \
			"// %s: see docs/SCRIPTING.md for the borg API.\nborg.on(\"load\", world => {\n\tborg.message(\"Welcome to \" + world.title);\n});\n\nborg.on(\"enter\", tile => {\n\tif (tile.id === 1) borg.message(\"Trigger 1 at \" + tile.x + \",\" + tile.y);\n});\n" % _code_path.get_file()
	_code_label.text = _code_path
	_center_tabs.current_tab = 1


func _save_script() -> void:
	if _code_path.is_empty():
		return
	DirAccess.make_dir_recursive_absolute(_code_path.get_base_dir())
	var f := FileAccess.open(_code_path, FileAccess.WRITE)
	if f == null:
		_status.text = "Can't write " + _code_path
		return
	f.store_string(_code.text)
	_status.text = "Saved " + _code_path


## Dev hook: OPENQBORG_SCREENSHOT=out.png saves a frame after loading, then quits.
func _maybe_screenshot() -> void:
	var out := OS.get_environment("OPENQBORG_SCREENSHOT")
	if out.is_empty():
		return
	var tab := OS.get_environment("OPENQBORG_TAB")
	if not tab.is_empty():
		_center_tabs.current_tab = int(tab)
	for i in 60:
		await get_tree().process_frame
	get_viewport().get_texture().get_image().save_png(out)
	get_tree().quit()


# --- Starter library ------------------------------------------------------------

enum LibKind { SPRITES, FLOORS, WALLS, SOUNDS, MUSIC, BACKDROPS, TEMPLATES }
const LIB_KINDS := ["Sprites", "Floor tiles", "Wall strips", "Sounds", "Music", "Backdrops",
		"Page & script templates"]

var _lib_kind: OptionButton
var _lib_list: ItemList
var _lib_info: Label
var _lib_play: Button


func _build_library_tab() -> Control:
	var box := VBoxContainer.new()
	box.name = "Library"
	if not library.available():
		var l := _label("The starter library wasn't found. Build it with tools/make_examples.gd.")
		box.add_child(l)
		return box
	var row := HBoxContainer.new()
	box.add_child(row)
	_lib_kind = OptionButton.new()
	for k in LIB_KINDS:
		_lib_kind.add_item(k)
	_lib_kind.item_selected.connect(func(_i): _refresh_library())
	row.add_child(_lib_kind)
	var use := Button.new()
	use.text = "Use in world"
	use.tooltip_text = "Adds the item to the world and selects it for painting (double-click works too)"
	use.pressed.connect(func():
		var sel := _lib_list.get_selected_items()
		if sel.size() > 0:
			_lib_use(sel[0]))
	row.add_child(use)
	_lib_play = Button.new()
	_lib_play.text = "▶ Preview"
	_lib_play.pressed.connect(_lib_preview)
	row.add_child(_lib_play)
	_lib_list = ItemList.new()
	_lib_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_lib_list.max_columns = 0
	_lib_list.icon_mode = ItemList.ICON_MODE_TOP
	_lib_list.fixed_column_width = 120
	_lib_list.fixed_icon_size = Vector2i(StarterLibrary.THUMB, StarterLibrary.THUMB)
	_lib_list.same_column_width = true
	_lib_list.item_activated.connect(_lib_use)
	_lib_list.item_selected.connect(_lib_describe)
	box.add_child(_lib_list)
	_lib_info = _label("Everything here was made for OpenQBORG and can be used in your worlds.")
	_lib_info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_lib_info)
	_refresh_library()
	return box


func _refresh_library() -> void:
	_lib_list.clear()
	var kind := _lib_kind.selected
	_lib_play.visible = kind == LibKind.SOUNDS or kind == LibKind.MUSIC
	var add := func(text: String, icon: Texture2D, meta: Dictionary):
		var i := _lib_list.add_item(text, icon)
		_lib_list.set_item_metadata(i, meta)
	match kind:
		LibKind.SPRITES:
			var sprites: Array = library.manifest.get("sprites", [])
			sprites.sort_custom(func(a, b): return a.category + a.name < b.category + b.name)
			for s in sprites:
				add.call(s.name, library.sprite_thumb(s.file), s)
		LibKind.FLOORS:
			add.call("Animated set", null, {"set": true, "name": "the animated floor set"})
			add.call("Still set", null, {"set": false, "name": "the still floor set"})
			var names := library.floor_names()
			for i in names.size():
				add.call(names[i], library.floor_thumb(i), {"index": i, "name": names[i]})
		LibKind.WALLS:
			add.call("Animated set", null, {"set": true, "name": "the animated wall set"})
			add.call("Still set", null, {"set": false, "name": "the still wall set"})
			var names := library.wall_names()
			for i in names.size():
				add.call(names[i], library.wall_thumb(i), {"index": i, "name": names[i]})
		LibKind.SOUNDS:
			for s in library.manifest.get("sounds", []):
				add.call("%s\n%s" % [s.name, s.file.get_extension().to_upper()], null, s)
		LibKind.MUSIC:
			for s in library.manifest.get("music", []):
				add.call("%s\n%s" % [s.name, s.file.get_extension().to_upper()], null, s)
		LibKind.BACKDROPS:
			for b in library.manifest.get("backdrops", []):
				add.call(b.name, library.backdrop_thumb(b.file), b)
		LibKind.TEMPLATES:
			add.call("World script", null, {"folder": "scripts", "file": "template.js", "name": "World script"})
			add.call("Page", null, {"folder": "html", "file": "page-template.html", "name": "Page"})


func _lib_describe(i: int) -> void:
	var m: Dictionary = _lib_list.get_item_metadata(i)
	match _lib_kind.selected:
		LibKind.SPRITES:
			_lib_info.text = "%s (%s). Adds it to the world's sprites and selects the Objects layer.%s" % [
					m.name, m.category, " Blocks walking: paint No-walk under it too." if m.get("blocks", false) else ""]
		LibKind.FLOORS when m.has("set"):
			_lib_info.text = "Switches the world to %s. Both sets have the same tiles in the same order, so painted floors stay put; the animated set (a GIF) makes water, the glowing pad and lava move." % m.name
		LibKind.WALLS when m.has("set"):
			_lib_info.text = "Switches the world to %s. Same strips, same order; the animated set (a GIF) makes the waterfall flow." % m.name
		LibKind.FLOORS:
			_lib_info.text = "%s. Selects the Floor layer with this tile; the world switches to the library's floor tiles if it used others." % m.name
		LibKind.WALLS:
			_lib_info.text = "%s. Selects No-walk / wall texture with this strip. Give the tiles a Wall height to raise them." % m.name
		LibKind.SOUNDS:
			_lib_info.text = "%s: a looping sound tile. Selects the Sounds layer to paint where it plays." % m.name
		LibKind.MUSIC:
			_lib_info.text = "%s: background music. Selects the Music layer to paint the region it covers." % m.name
		LibKind.BACKDROPS:
			_lib_info.text = "%s: the panorama behind the world, with a matching background colour." % m.name
		LibKind.TEMPLATES:
			_lib_info.text = "Copies the %s template into your world (save the world first)." % m.name.to_lower()


func _lib_use(i: int) -> void:
	var m: Dictionary = _lib_list.get_item_metadata(i)
	var before := level.serialize()
	match _lib_kind.selected:
		LibKind.SPRITES:
			_select_paint("obj", _ensure_ext_file("spr", m.file))
		LibKind.FLOORS:
			if m.has("set"):
				library.use_floors(level, "flr", m.set)
			else:
				if not library.uses_library_floors(level):
					library.use_floors(level)
				_select_paint("flr", m.index)
		LibKind.WALLS:
			if m.has("set"):
				library.use_walls(level, m.set)
			else:
				if not library.uses_library_walls(level):
					library.use_walls(level)
				_select_paint("wal", m.index + 1)
		LibKind.SOUNDS:
			_select_paint("wav", _ensure_ext_file("wav", m.file))
		LibKind.MUSIC:
			_select_paint("mid", _ensure_ext_file("mid", m.file))
		LibKind.BACKDROPS:
			library.set_backdrop(level, m)
		LibKind.TEMPLATES:
			_lib_use_template(m)
			return
	var after := level.serialize()
	if after != before:
		undo.create_action("Use %s from library" % m.name)
		undo.add_do_method(_restore_snapshot.bind(after))
		undo.add_undo_method(_restore_snapshot.bind(before))
		undo.commit_action(false)
		_mark_unsaved()
		if not path.is_empty():
			library.copy_used(level, path.get_base_dir())
		_level_to_props()
		_refresh_resources()
		_reload_world()
	_status.text = "Using %s from the starter library." % m.name


## Adds `file` to an <ext> list if needed; returns its 1-based index.
func _ensure_ext_file(tag: String, file: String) -> int:
	var files := level.ext_files(tag)
	var i := files.find(file)
	if i < 0:
		files.append(file)
		level.set_ext_files(tag, files)
		i = files.size() - 1
	return i + 1


## Selects a layer and value for painting and shows the 3D view.
func _select_paint(layer: String, value: int) -> void:
	for i in LAYERS.size():
		if LAYERS[i][0] == layer:
			_layer_list.select(i)
	_refresh_values()
	_refresh_overlay()
	_value_spin.value = value
	_center_tabs.current_tab = 0


func _lib_use_template(m: Dictionary) -> void:
	if path.is_empty():
		_status.text = "Save the world first: templates are copied into its folder."
		return
	var world_dir := path.get_base_dir()
	if m.folder == "scripts":
		library.copy_file("scripts", m.file, world_dir)
		_ensure_ext_file("js", m.file)
		_mark_unsaved()
		_refresh_resources()
		_res_kind.select(RESOURCE_LISTS.map(func(r): return r[0]).find("js"))
		_refresh_resources()
		_res_list.select(level.ext_files("js").find(m.file))
		_res_edit_script()
		_status.text = "Copied scripts/%s into the world and opened it." % m.file
	else:
		for f in [m.file, "style.css", "qborg.js"]:
			library.copy_file("html", f, world_dir)
		_status.text = "Copied html/%s (with style.css and qborg.js) into the world. Link it from a .url shortcut in domains/." % m.file


func _lib_preview() -> void:
	var sel := _lib_list.get_selected_items()
	if not music.current.is_empty() or sel.is_empty():
		music.play_url("", fetcher)
		_lib_play.text = "▶ Preview"
		return
	var m: Dictionary = _lib_list.get_item_metadata(sel[0])
	music.play_url("file://" + library.path("media", m.file), fetcher)
	_lib_play.text = "■ Stop"
