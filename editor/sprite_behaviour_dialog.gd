# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 Mark Toman and OpenQBORG contributors
class_name SpriteBehaviourDialog
extends AcceptDialog
## Edits a sprite's animation and CWS3 behaviours (general, mouse-over,
## click, proximity) with a live preview, and saves them into the .sprite.

signal saved(path: String)

const GROUP_NAMES := ["General", "Mouse-over", "Click", "Proximity"]
const PREVIEW := 160

var sprite: CWSprite
var file_path := ""

var _preview: TextureRect
var _preview_node := Sprite3D.new()
var _behaviour: SpriteBehaviour
var _frames: Array[Texture2D] = []
var _animate: CheckBox
var _durations: LineEdit
var _proximity: SpinBox
var _rows: Array[Dictionary] = []
var _playing_group := -1
var _info: Label


## Opens the sprite at `path` (a world's objects/ file). Returns false if it
## can't be read.
func open(path: String) -> bool:
	var s := CWSprite.decode(FileAccess.get_file_as_bytes(path), path)
	if s == null:
		return false
	sprite = s
	file_path = path
	if sprite.groups.is_empty():
		sprite.groups = sprite.default_groups()
	title = "Sprite behaviour: " + path.get_file()
	_build()
	_load_fields()
	_preview_node.texture = ImageTexture.create_from_image(sprite.image)
	_preview_node.vframes = maxi(1, sprite.cell_count)
	_restart(CWSprite.Group.GENERAL)
	return true


func _build() -> void:
	ok_button_text = "Save"
	add_cancel_button("Cancel")
	confirmed.connect(_save)
	var root := HBoxContainer.new()
	add_child(root)

	var left := VBoxContainer.new()
	root.add_child(left)
	_preview = TextureRect.new()
	_preview.custom_minimum_size = Vector2(PREVIEW, PREVIEW)
	_preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_preview.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	left.add_child(_preview)
	_info = Label.new()
	_info.text = "%d frame(s), %d×%d px" % [sprite.cell_count, sprite.cell_width, sprite.cell_height]
	left.add_child(_info)

	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.add_child(right)
	var top := GridContainer.new()
	top.columns = 2
	right.add_child(top)
	_animate = CheckBox.new()
	_animate.text = "Animate the general group on load"
	_animate.toggled.connect(func(_on): _apply_and_restart(CWSprite.Group.GENERAL))
	top.add_child(Label.new())
	top.add_child(_animate)
	top.add_child(_label("Frame durations (ms)"))
	_durations = LineEdit.new()
	_durations.custom_minimum_size.x = 260
	_durations.tooltip_text = "One per frame, separated by commas"
	_durations.text_submitted.connect(func(_t): _apply_and_restart(_playing_group))
	top.add_child(_durations)
	top.add_child(_label("Proximity distance (px)"))
	_proximity = SpinBox.new()
	_proximity.max_value = 65535
	_proximity.tooltip_text = "256 px = one tile"
	top.add_child(_proximity)

	var grid := GridContainer.new()
	grid.columns = 9
	right.add_child(grid)
	for h in ["", "On", "From", "To", "Repeat", "End", "Revert on exit", "Revert on stop", ""]:
		grid.add_child(_label(h))
	var last := maxi(0, sprite.cell_count - 1)
	for g in 4:
		var row := {}
		grid.add_child(_label(GROUP_NAMES[g]))
		row.enabled = CheckBox.new()
		grid.add_child(row.enabled)
		for key in ["from", "to"]:
			row[key] = _spin(0, last)
			grid.add_child(row[key])
		row.repeat = _spin(0, 999)
		row.repeat.tooltip_text = "0 = loop while active"
		grid.add_child(row.repeat)
		row.end = _spin(-1, last)
		row.end.tooltip_text = "Frame to hold when done; -1 = back to General"
		grid.add_child(row.end)
		row.on_exit = CheckBox.new()
		row.on_exit.tooltip_text = "Back to General when the mouse leaves / the viewer walks away"
		grid.add_child(row.on_exit)
		row.on_stop = CheckBox.new()
		row.on_stop.tooltip_text = "Back to General when this animation finishes"
		grid.add_child(row.on_stop)
		var try := Button.new()
		try.text = "▶ Try"
		try.pressed.connect(_apply_and_restart.bind(g))
		grid.add_child(try)
		_rows.append(row)
	var help := _label("Mouse-over, click and proximity take over from General while their trigger is active. " +
			"Frames play From→To (backwards if From > To), Repeat times, then hold End.")
	help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	help.custom_minimum_size.x = 520
	right.add_child(help)


static func _label(t: String) -> Label:
	var l := Label.new()
	l.text = t
	return l


static func _spin(lo: int, hi: int) -> SpinBox:
	var s := SpinBox.new()
	s.min_value = lo
	s.max_value = hi
	s.custom_minimum_size.x = 64
	return s


func _load_fields() -> void:
	_animate.set_pressed_no_signal(sprite.animate_on_load)
	_durations.text = ", ".join(Array(sprite.frame_durations).map(func(d): return str(d)))
	_proximity.value = sprite.proximity_distance
	for g in 4:
		var grp: Dictionary = sprite.groups[g]
		var row := _rows[g]
		row.enabled.button_pressed = grp.enabled
		row.from.value = grp.from
		row.to.value = grp.to
		row.repeat.value = grp.repeat
		row.end.value = grp.end
		row.on_exit.button_pressed = grp.revert & CWSprite.REVERT_ON_EXIT
		row.on_stop.button_pressed = grp.revert & CWSprite.REVERT_ON_STOP


func _apply_fields() -> void:
	sprite.animate_on_load = _animate.button_pressed
	var durs := PackedInt32Array()
	for part in _durations.text.split(",", false):
		durs.append(maxi(1, int(part.strip_edges())))
	while durs.size() < sprite.frame_count:
		durs.append(sprite.default_duration)
	sprite.frame_durations = durs.slice(0, maxi(1, sprite.frame_count))
	sprite.proximity_distance = int(_proximity.value)
	for g in 4:
		var row := _rows[g]
		sprite.groups[g] = {"enabled": row.enabled.button_pressed, "from": int(row.from.value),
				"to": int(row.to.value), "repeat": int(row.repeat.value), "end": int(row.end.value),
				"revert": (CWSprite.REVERT_ON_EXIT if row.on_exit.button_pressed else 0)
						| (CWSprite.REVERT_ON_STOP if row.on_stop.button_pressed else 0)}


func _apply_and_restart(g: int) -> void:
	_apply_fields()
	_restart(maxi(g, 0))


func _restart(g: int) -> void:
	_playing_group = g
	_behaviour = SpriteBehaviour.new(_preview_node, sprite, Vector2i.ZERO)
	if g != CWSprite.Group.GENERAL:
		# Try a group even if it's switched off, so it can be tuned first.
		var was: bool = sprite.groups[g].enabled
		sprite.groups[g].enabled = true
		_behaviour.start(g)
		sprite.groups[g].enabled = was
	_show_frame()


func _process(delta: float) -> void:
	if _behaviour != null and visible:
		_behaviour.tick(delta * 1000.0)
		_show_frame()


func _show_frame() -> void:
	var cell := Rect2(0, _preview_node.frame * sprite.cell_height, sprite.cell_width, sprite.cell_height)
	var atlas := _preview.texture as AtlasTexture
	if atlas == null or atlas.atlas != _preview_node.texture:
		atlas = AtlasTexture.new()
		atlas.atlas = _preview_node.texture
		_preview.texture = atlas
	atlas.region = cell


func _save() -> void:
	_apply_fields()
	var f := FileAccess.open(file_path, FileAccess.WRITE)
	if f == null:
		return
	f.store_buffer(sprite.to_png_bytes())
	f.close()
	saved.emit(file_path)


func _exit_tree() -> void:
	_preview_node.free()
