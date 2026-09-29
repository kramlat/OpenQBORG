# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 Mark Toman and OpenQBORG contributors
class_name HtmlView
extends PanelContainer
## HTML view for world pages and ordinary web pages, rendered by godot-cef
## (Chromium) when the addon is installed. Without it, pages fall back to the
## system browser.

## A page asked the player to do something: type is "borg" (raw borg:// URL,
## `base` is the page it came from), "world", "web", "moveTile", "tileValue"
## or "dialog" (alert/confirm/prompt text).
signal page_request(msg: Dictionary)
## The page (or a redirect, or a link the user followed) moved to `url`.
signal address_changed(url: String)
signal title_changed(title: String)

const BRIDGE_SCRIPT := "res://web/borg_bridge.js"
## Chromium network errors worth retrying (refused, reset, closed, timed out,
## empty response): busy servers such as the Wayback Machine refuse bursts.
const RETRY_ERRORS := [100, 101, 102, 7, 118, 324]
const MAX_RETRIES := 3
## Where the player serves Ruffle; set before pages are created ("" = none).
static var ruffle_base := ""

var current_url := ""
var borg_location := ""
var title := ""
var _cef: Control
var _audio: AudioStreamPlayer
var _fallback_label: Label
var _fallback_button: Button
var _retries := 0


## The bridge script, told where Ruffle is (for Flash in pages).
static func preload_source() -> String:
	return "window.__OQB_RUFFLE = %s;\n" % JSON.stringify(ruffle_base) + FileAccess.get_file_as_string(BRIDGE_SCRIPT)


static func cef_available() -> bool:
	return ClassDB.class_exists("CefTexture")


func _ready() -> void:
	if cef_available():
		_cef = ClassDB.instantiate("CefTexture")
		_cef.set("popup_policy", 2) # SIGNAL_ONLY: we decide where popups go
		_cef.set("background_color", Color.WHITE)
		_cef.set("preload_script", preload_source())
		_cef.set("url", "about:blank")
		_cef.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_cef.size_flags_vertical = Control.SIZE_EXPAND_FILL
		add_child(_cef)
		_cef.connect("ipc_message", _on_ipc_message)
		_cef.connect("load_error", _on_load_error)
		_cef.connect("url_changed", _on_url_changed)
		_cef.connect("popup_requested", _on_popup_requested)
		_cef.connect("load_finished", _on_load_finished)
		_cef.connect("load_started", _on_load_started)
		_cef.connect("download_requested", _on_download_requested)
		_cef.connect("console_message", func(level: int, message: String, source: String, line: int):
			print_verbose("page console [%d] %s (%s:%d)" % [level, message, source.get_file(), line]))
		_cef.connect("title_changed", func(t: String): title = t; title_changed.emit(t))
		_audio = attach_audio(_cef, self)
	else:
		var box := VBoxContainer.new()
		box.alignment = BoxContainer.ALIGNMENT_CENTER
		_fallback_label = Label.new()
		_fallback_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_fallback_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_fallback_label.text = "Install godot-cef to show pages here\n(tools/fetch-assets.sh cef)."
		_fallback_button = Button.new()
		_fallback_button.text = "Open page in browser"
		_fallback_button.disabled = true
		_fallback_button.pressed.connect(func(): OS.shell_open(current_url))
		box.add_child(_fallback_label)
		box.add_child(_fallback_button)
		add_child(box)


func navigate(url: String) -> void:
	if OS.is_debug_build():
		print_verbose("HtmlView: " + url)
	if url == current_url:
		return
	current_url = url
	_retries = 0
	if _cef != null:
		_cef.set("url", url)
	else:
		_fallback_label.text = url.get_file() if not url.is_empty() else "(no page)"
		_fallback_button.disabled = url.is_empty()


func clear() -> void:
	navigate("about:blank" if _cef != null else "")


# --- Browser navigation -------------------------------------------------------

func can_go_back() -> bool:
	return _cef != null and _cef.call("can_go_back")


func can_go_forward() -> bool:
	return _cef != null and _cef.call("can_go_forward")


func go_back() -> void:
	if can_go_back():
		_cef.call("go_back")


func go_forward() -> void:
	if can_go_forward():
		_cef.call("go_forward")


func reload() -> void:
	if _cef != null:
		_cef.call("reload")


## A .borg address is a world, not a page: hand it to the player instead of
## letting Chromium show the XML.
static func is_world_url(url: String) -> bool:
	return url.get_slice("?", 0).get_slice("#", 0).to_lower().ends_with(".borg")


func _on_ipc_message(message: String) -> void:
	var msg = JSON.parse_string(message)
	if msg is Dictionary and msg.has("type"):
		page_request.emit(msg)


func _on_load_finished(url: String, status: int) -> void:
	if status == 429 or status == 503:
		_retry(url)
		return
	if not borg_location.is_empty():
		_cef.call("eval", "window.external && (window.external.BorgLocation = %s);" % JSON.stringify(borg_location))


# Fallbacks for borg:// navigations the bridge script didn't catch.
func _on_load_error(url: String, code: int, _text: String) -> void:
	if url.to_lower().begins_with("borg"):
		page_request.emit({"type": "borg", "url": url, "base": current_url})
	elif absi(code) in RETRY_ERRORS:
		_retry(url)


## Loads the page again after 1, 2, then 4 s, if it is still the one wanted.
func _retry(url: String) -> void:
	if url != current_url or _retries >= MAX_RETRIES:
		return
	var delay := pow(2.0, _retries)
	_retries += 1
	await get_tree().create_timer(delay).timeout
	if url == current_url and _cef != null:
		_cef.call("reload")


func _on_load_started(url: String) -> void:
	print_verbose("HtmlView load_started: ", url)
	if is_world_url(url) and not url.to_lower().begins_with("borg"):
		_cef.call("stop_loading")
		page_request.emit({"type": "world", "url": url})


func _on_url_changed(url: String) -> void:
	print_verbose("HtmlView url_changed: ", url)
	if url.to_lower().begins_with("borg"):
		_cef.call("stop_loading")
		page_request.emit({"type": "borg", "url": url, "base": current_url})
	elif is_world_url(url):
		_cef.call("stop_loading")
		page_request.emit({"type": "world", "url": url})
	else:
		current_url = url
		address_changed.emit(url)


## Servers usually send .borg files as a download (octet-stream); those are
## worlds. Other downloads are ignored: the player doesn't save files.
func _on_download_requested(info: Object) -> void:
	var url := str(info.get("url"))
	if is_world_url(url) or str(info.get("suggested_file_name")).to_lower().ends_with(".borg"):
		page_request.emit({"type": "world", "url": url})


func _on_popup_requested(url: String, _disposition: int, _user_gesture: bool) -> void:
	if url.to_lower().begins_with("borg"):
		page_request.emit({"type": "borg", "url": url, "base": current_url})
	elif is_world_url(url):
		page_request.emit({"type": "world", "url": url})
	else:
		navigate(url)


## Routes a CefTexture's sound (HTML5 <audio>/<video>, WebAudio) through
## Godot's mixer instead of straight to the OS, when godot_cef/audio/
## enable_audio_capture is on. Call push_audio() every frame.
static func attach_audio(cef: Control, parent: Node) -> AudioStreamPlayer:
	if not cef.call("is_audio_capture_enabled"):
		return null
	var p := AudioStreamPlayer.new()
	p.stream = cef.call("create_audio_stream")
	parent.add_child(p)
	p.play()
	return p


static func push_audio(cef: Control, player: AudioStreamPlayer) -> void:
	if cef == null or player == null or not player.playing:
		return
	var playback := player.get_stream_playback()
	if playback != null:
		cef.call("push_audio_to_playback", playback)


func _process(_delta: float) -> void:
	push_audio(_cef, _audio)
	# A page covered by the 3D view (or hidden) shouldn't keep making noise.
	if _audio != null:
		_audio.volume_db = 0.0 if is_visible_in_tree() else -80.0
