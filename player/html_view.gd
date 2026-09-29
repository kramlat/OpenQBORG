class_name HtmlView
extends PanelContainer
## HTML pane for world pages, rendered by godot-cef (Chromium) when the
## addon is installed. Without it, pages fall back to the system browser.

## A page asked the player to do something: kind is "borg" (raw borg:// URL,
## `base` is the page it came from), "world", "web", "moveTile" or "tileValue".
signal page_request(msg: Dictionary)

const BRIDGE_SCRIPT := "res://web/borg_bridge.js"

var current_url := ""
var borg_location := ""
var _cef: Control
var _fallback_label: Label
var _fallback_button: Button


static func cef_available() -> bool:
	return ClassDB.class_exists("CefTexture")


func _ready() -> void:
	if cef_available():
		_cef = ClassDB.instantiate("CefTexture")
		_cef.set("popup_policy", 2) # SIGNAL_ONLY: we decide where popups go
		_cef.set("background_color", Color.WHITE)
		_cef.set("preload_script_path", BRIDGE_SCRIPT)
		_cef.set("url", "about:blank")
		_cef.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_cef.size_flags_vertical = Control.SIZE_EXPAND_FILL
		add_child(_cef)
		_cef.connect("ipc_message", _on_ipc_message)
		_cef.connect("load_error", _on_load_error)
		_cef.connect("url_changed", _on_url_changed)
		_cef.connect("popup_requested", _on_popup_requested)
		_cef.connect("load_finished", _on_load_finished)
	else:
		var box := VBoxContainer.new()
		box.alignment = BoxContainer.ALIGNMENT_CENTER
		_fallback_label = Label.new()
		_fallback_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_fallback_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_fallback_label.text = "Install godot-cef to show world pages here\n(tools/fetch-godot-cef.sh)."
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
	if _cef != null:
		_cef.set("url", url)
	else:
		_fallback_label.text = url.get_file() if not url.is_empty() else "(no page)"
		_fallback_button.disabled = url.is_empty()


func clear() -> void:
	navigate("about:blank" if _cef != null else "")


func _on_ipc_message(message: String) -> void:
	var msg = JSON.parse_string(message)
	if msg is Dictionary and msg.has("type"):
		page_request.emit(msg)


func _on_load_finished(_url: String, _status: int) -> void:
	if not borg_location.is_empty():
		_cef.call("eval", "window.external && (window.external.BorgLocation = %s);" % JSON.stringify(borg_location))


# Fallbacks for borg:// navigations the bridge script didn't catch.
func _on_load_error(url: String, _code: int, _text: String) -> void:
	if url.to_lower().begins_with("borg"):
		page_request.emit({"type": "borg", "url": url, "base": current_url})


func _on_url_changed(url: String) -> void:
	if url.to_lower().begins_with("borg"):
		_cef.call("stop_loading")
		page_request.emit({"type": "borg", "url": url, "base": current_url})
	else:
		current_url = url


func _on_popup_requested(url: String, _disposition: int, _user_gesture: bool) -> void:
	if url.to_lower().begins_with("borg"):
		page_request.emit({"type": "borg", "url": url, "base": current_url})
	else:
		navigate(url)
