# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 Mark Toman and OpenQBORG contributors
class_name WebSurface
extends SubViewport
## A live web page (or video, or SWF through Ruffle) for a surface in the 3D
## world: Chromium renders into this offscreen viewport, whose texture goes on
## the surface; its sound plays from the surface through a positional player;
## clicks and mouse movement on the surface are passed in as page input.

## Requests from the page (as HtmlView.page_request), tagged with surface_id.
signal page_request(msg: Dictionary)

var surface_id := ""
var url := ""
var cef: Control
var audio: AudioStreamPlayer3D
var _pressed := false


func _init(p_url: String, p_size: Vector2i) -> void:
	url = p_url
	size = p_size
	render_target_update_mode = SubViewport.UPDATE_ALWAYS
	handle_input_locally = true
	gui_embed_subwindows = true


func _ready() -> void:
	cef = ClassDB.instantiate("CefTexture")
	cef.set("background_color", Color.BLACK)
	cef.set("popup_policy", 1) # REDIRECT: popups replace the page on the screen
	cef.set("preload_script", HtmlView.preload_source())
	# Sized explicitly (not anchored): inside an offscreen SubViewport the
	# anchors resolve against a scaled rect and the page came out 2x too big.
	cef.position = Vector2.ZERO
	# Chromium may render at a display-scaled resolution; always fit the
	# whole page to the viewport.
	cef.set("expand_mode", TextureRect.EXPAND_IGNORE_SIZE)
	cef.set("stretch_mode", TextureRect.STRETCH_SCALE)
	cef.size = Vector2(size)
	cef.set("url", url)
	add_child(cef)
	cef.connect("ipc_message", func(message: String):
		var msg = JSON.parse_string(message)
		if msg is Dictionary and msg.has("type"):
			msg["surface"] = surface_id
			page_request.emit(msg))
	cef.connect("console_message", func(level: int, message: String, source: String, line: int):
		print_verbose("surface console [%d] %s (%s:%d)" % [level, message, source.get_file(), line]))
	if cef.call("is_audio_capture_enabled"):
		audio = AudioStreamPlayer3D.new()
		audio.stream = cef.call("create_audio_stream")
		audio.unit_size = 6.0
		audio.max_distance = 0.0 # audible across a whole theatre
		audio.autoplay = true


## Puts the surface's sound at `center` in the 3D scene `parent`.
func place_audio(parent: Node, center: Vector3, span: float) -> void:
	if audio == null:
		return
	if audio.get_parent() != parent:
		if audio.get_parent() != null:
			audio.get_parent().remove_child(audio)
		parent.add_child(audio)
	audio.position = center
	audio.unit_size = maxf(3.0, span * 1.5)


func _process(_delta: float) -> void:
	if cef != null and cef.size != Vector2(size):
		cef.size = Vector2(size)
	if audio != null and audio.is_inside_tree() and audio.playing:
		var playback := audio.get_stream_playback()
		if playback != null:
			cef.call("push_audio_to_playback", playback)


## Mouse movement at `uv` (0..1 across the surface).
func pointer_move(uv: Vector2) -> void:
	var e := InputEventMouseMotion.new()
	e.position = uv * Vector2(size)
	e.global_position = e.position
	e.button_mask = MOUSE_BUTTON_MASK_LEFT if _pressed else 0
	push_input(e)


## A left click (press + release) at `uv`.
func click(uv: Vector2) -> void:
	for pressed in [true, false]:
		var e := InputEventMouseButton.new()
		e.button_index = MOUSE_BUTTON_LEFT
		e.pressed = pressed
		e.position = uv * Vector2(size)
		e.global_position = e.position
		_pressed = pressed
		push_input(e)


func scroll(uv: Vector2, up: bool) -> void:
	var e := InputEventMouseButton.new()
	e.button_index = MOUSE_BUTTON_WHEEL_UP if up else MOUSE_BUTTON_WHEEL_DOWN
	e.pressed = true
	e.position = uv * Vector2(size)
	e.global_position = e.position
	push_input(e)


func _exit_tree() -> void:
	if audio != null and is_instance_valid(audio):
		audio.queue_free()


## Sends `data` to the page (it arrives through qborg.onMessage).
func send_message(data: Variant) -> void:
	if cef != null:
		cef.call("send_ipc_message", JSON.stringify({"type": "surfaceMessage", "data": data}))
