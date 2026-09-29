# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 Mark Toman and OpenQBORG contributors
class_name LocalPageServer
extends Node
## Serves the pages of *local* worlds over http://127.0.0.1 so Chromium treats
## them like the web pages they originally were. CYBERWORLD pages keep game
## state in cookies, which Chromium refuses on file://.
##
## Only loopback, a random port, a random per-session token as the first path
## segment, and only files under directories of worlds the user opened.

const MIME := {
	"html": "text/html", "htm": "text/html", "css": "text/css", "js": "text/javascript",
	"json": "application/json", "gif": "image/gif", "png": "image/png", "jpg": "image/jpeg",
	"jpeg": "image/jpeg", "svg": "image/svg+xml", "webp": "image/webp", "ico": "image/x-icon",
	"wav": "audio/wav", "mp3": "audio/mpeg", "ogg": "audio/ogg", "mid": "audio/midi",
	"swf": "application/x-shockwave-flash", "txt": "text/plain", "xml": "text/xml",
	"borg": "text/xml", "url": "text/plain",
}

var _server := TCPServer.new()
var _token := ""
var _roots: PackedStringArray = []
var _clients: Array = []


func _ready() -> void:
	var crypto := Crypto.new()
	_token = crypto.generate_random_bytes(12).hex_encode()
	for attempt in 20:
		if _server.listen(randi_range(20000, 60000), "127.0.0.1") == OK:
			break


func is_running() -> bool:
	return _server.is_listening()


func origin() -> String:
	return "http://127.0.0.1:%d/%s" % [_server.get_local_port(), _token]


## Allows serving everything under `dir` (an absolute local directory).
func allow_root(dir: String) -> void:
	dir = BorgUrl.normalize(dir.trim_suffix("/") + "/")
	if not dir in _roots:
		_roots.append(dir)


## file:///x/y.html -> http://127.0.0.1:port/token/x/y.html (when allowed).
func to_served(url: String) -> String:
	if not is_running() or not BorgUrl.is_local(url):
		return url
	var path := BorgUrl.local_path(url)
	return origin() + path.uri_encode().replace("%2F", "/") if _is_allowed(path) else url


## The reverse, so worlds reached through page links show their real path.
func to_local(url: String) -> String:
	var o := origin()
	if is_running() and url.begins_with(o + "/"):
		return "file://" + url.substr(o.length()).uri_decode()
	return url


func _is_allowed(path: String) -> bool:
	path = BorgUrl.normalize(path)
	for root in _roots:
		if path.begins_with(root):
			return true
	return false


func _process(_delta: float) -> void:
	while _server.is_connection_available():
		_clients.append({"peer": _server.take_connection(), "buf": PackedByteArray(),
				"t": Time.get_ticks_msec()})
	for c in _clients.duplicate():
		var peer: StreamPeerTCP = c.peer
		peer.poll()
		var status := peer.get_status()
		if status != StreamPeerTCP.STATUS_CONNECTED or Time.get_ticks_msec() - c.t > 10000:
			_clients.erase(c)
			continue
		var avail := peer.get_available_bytes()
		if avail > 0:
			c.buf.append_array(peer.get_data(avail)[1])
		var text: String = c.buf.get_string_from_ascii()
		if text.contains("\r\n\r\n"):
			_respond(peer, text.get_slice("\r\n", 0))
			peer.disconnect_from_host()
			_clients.erase(c)


func _respond(peer: StreamPeerTCP, request_line: String) -> void:
	var parts := request_line.split(" ")
	if parts.size() < 2 or not (parts[0] == "GET" or parts[0] == "HEAD"):
		_send(peer, 405, "text/plain", "Method not allowed".to_utf8_buffer())
		return
	var target := parts[1].get_slice("?", 0).get_slice("#", 0)
	var prefix := "/" + _token + "/"
	if not target.begins_with(prefix):
		_send(peer, 404, "text/plain", "Not found".to_utf8_buffer())
		return
	var path := BorgUrl.normalize("/" + target.substr(prefix.length()).uri_decode())
	if not _is_allowed(path):
		_send(peer, 403, "text/plain", "Forbidden".to_utf8_buffer())
		return
	path = BorgUrl.resolve_case(path)
	if DirAccess.dir_exists_absolute(path):
		path = BorgUrl.resolve_case(path.path_join("index.html"))
	if not FileAccess.file_exists(path):
		_send(peer, 404, "text/plain", "Not found".to_utf8_buffer())
		return
	var body := FileAccess.get_file_as_bytes(path) if parts[0] == "GET" else PackedByteArray()
	_send(peer, 200, MIME.get(path.get_extension().to_lower(), "application/octet-stream"), body)


func _send(peer: StreamPeerTCP, code: int, mime: String, body: PackedByteArray) -> void:
	var reason: String = {200: "OK", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed"}.get(code, "")
	var head := "HTTP/1.1 %d %s\r\nContent-Type: %s\r\nContent-Length: %d\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n" \
			% [code, reason, mime, body.size()]
	peer.set_no_delay(true)
	peer.put_data(head.to_ascii_buffer())
	var sent := 0
	while sent < body.size():
		var chunk := body.slice(sent, mini(sent + 65536, body.size()))
		var err := peer.put_data(chunk)
		if err != OK:
			return
		sent += chunk.size()
