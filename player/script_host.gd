class_name ScriptHost
extends Control
## OpenQBORG extension: runs a world's JavaScript (<ext><js>) in a hidden
## Chromium page via godot-cef. Scripts see a `borg` API (web/script_host.html)
## and talk to the player over IPC. Without godot-cef, scripts don't run.

## A script asked for something: setTile, teleport, go, showPage,
## showSidePage, message, log.
signal request(msg: Dictionary)

const HOST_PAGE := "res://web/script_host.html"

var _cef: Control
var _ready_page := false
var _queue: Array[Dictionary] = []
var _generation := 0


static func available() -> bool:
	return HtmlView.cef_available()


func _ready() -> void:
	# Present but invisible: the page must stay alive to run timers.
	custom_minimum_size = Vector2(1, 1)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	modulate = Color(1, 1, 1, 0)


## Starts a fresh script context for `world` (drops the previous one).
func start(world: BorgWorld, player_state: Dictionary) -> void:
	stop()
	if world.scripts.is_empty() or not available():
		return
	_cef = ClassDB.instantiate("CefTexture")
	_cef.set("enable_accelerated_osr", false)
	_cef.set("popup_policy", 0)
	_cef.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_cef.size = Vector2(1, 1)
	_generation += 1
	_cef.set("url", HOST_PAGE + "?g=%d" % _generation)
	add_child(_cef)
	_cef.connect("ipc_message", _on_ipc_message)
	var layers := {}
	for name in world.level.layers:
		layers[name] = Array(world.level.layers[name])
	_send({"type": "init", "world": {"width": world.level.width, "height": world.level.height,
			"title": world.level.meta.get("Title", ""), "url": world.base_url},
			"layers": layers, "player": player_state, "scripts": world.scripts})


func stop() -> void:
	if _cef != null:
		_cef.queue_free()
		_cef = null
	_ready_page = false
	_queue.clear()


func is_running() -> bool:
	return _cef != null


## event: "enter", "leave" or "click".
func send_event(event: String, tile: Vector2i, id: int, player_state: Dictionary) -> void:
	if _cef != null:
		_send({"type": "event", "event": event, "x": tile.x, "y": tile.y, "id": id,
				"player": player_state})


func sync_layer(layer: String, grid: PackedByteArray) -> void:
	if _cef != null:
		_send({"type": "tiles", "layer": layer, "grid": Array(grid)})


func _send(msg: Dictionary) -> void:
	if _ready_page:
		_cef.call("send_ipc_message", JSON.stringify(msg))
	else:
		_queue.append(msg)


func _on_ipc_message(message: String) -> void:
	var msg = JSON.parse_string(message)
	if not msg is Dictionary:
		return
	if msg.get("type") == "ready":
		_ready_page = true
		for queued in _queue:
			_cef.call("send_ipc_message", JSON.stringify(queued))
		_queue.clear()
	else:
		request.emit(msg)
