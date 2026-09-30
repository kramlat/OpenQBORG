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
##
## Pages of worlds on archive hosts (archive.org, the Wayback Machine) are
## proxied the same way, under __remote__/<scheme>/<host>/<path>: archive.org
## sends HTML inside ZIPs as plain text from a view_archive.php address that
## breaks relative links, and pages on public sites may not load Ruffle from
## loopback. Proxied, they get real types, real folder paths, the fetcher's
## disk cache and retries, and Ruffle from the same origin.

const MIME := {
	"html": "text/html", "htm": "text/html", "css": "text/css", "js": "text/javascript",
	"json": "application/json", "gif": "image/gif", "png": "image/png", "jpg": "image/jpeg",
	"jpeg": "image/jpeg", "svg": "image/svg+xml", "webp": "image/webp", "ico": "image/x-icon",
	"wav": "audio/wav", "mp3": "audio/mpeg", "ogg": "audio/ogg", "mid": "audio/midi",
	"wasm": "application/wasm", "mjs": "text/javascript",
	"swf": "application/x-shockwave-flash", "txt": "text/plain", "xml": "text/xml",
	"borg": "text/xml", "url": "text/plain",
}

var _server := TCPServer.new()
var _token := ""
var _roots: PackedStringArray = []
var _clients: Array = []
## Where Ruffle (res://web/ruffle, tools/fetch-assets.sh ruffle) is served.
const RUFFLE_DIR := "__ruffle__"
const OQB_DIR := "__oqb__"
const OQB_PAGES := ["swf.html"]
const REMOTE_DIR := "__remote__"
## Fetches proxied files; set by the player.
var fetcher: BorgFetcher
## Remote folders (URL prefixes ending in /) that may be proxied.
var _remote_roots: PackedStringArray = []
## Script-made HTML5 pages for surfaces, by name (see set_inline_page).
var _inline := {}


## Serves `html` at a stable address (script-made surface screens); a
## <base> makes its relative links resolve against `base_url`.
func set_inline_page(name: String, html: String, base_url: String) -> String:
	var key := name.uri_encode() + ".html"
	_inline[key] = "<base href=\"%s\">\n%s" % [to_served(base_url).xml_escape(true), html]
	return helper_page("inline/" + key) + "?v=%d" % hash(html)


## Address of one of OpenQBORG's helper pages.
func helper_page(page: String) -> String:
	return origin() + "/" + OQB_DIR + "/" + page


## Base URL of the served Ruffle build, or "" when it isn't installed.
func ruffle_base() -> String:
	if not is_running() or not FileAccess.file_exists("res://web/ruffle/ruffle.js"):
		return ""
	return origin() + "/" + RUFFLE_DIR + "/"


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


## Allows proxying everything under the remote folder `dir_url`.
func allow_remote_root(dir_url: String) -> void:
	dir_url = dir_url.trim_suffix("/") + "/"
	if not dir_url in _remote_roots:
		_remote_roots.append(dir_url)


## file:///x/y.html -> http://127.0.0.1:port/token/x/y.html (when allowed), and
## https://host/p/y.html -> http://127.0.0.1:port/token/__remote__/https/host/p/y.html
## for allowed remote folders.
func to_served(url: String) -> String:
	if is_running() and _is_remote_allowed(url):
		return origin() + "/" + REMOTE_DIR + "/" + url.get_slice("://", 0) + "/" + url.get_slice("://", 1)
	if not is_running() or not BorgUrl.is_local(url):
		return url
	var path := BorgUrl.local_path(url)
	return origin() + path.uri_encode().replace("%2F", "/") if _is_allowed(path) else url


## The reverse, so worlds reached through page links show their real path.
func to_local(url: String) -> String:
	var o := origin()
	var remote := o + "/" + REMOTE_DIR + "/"
	if is_running() and url.begins_with(remote):
		var rest := url.substr(remote.length())
		return rest.get_slice("/", 0) + "://" + rest.substr(rest.find("/") + 1)
	if is_running() and url.begins_with(o + "/"):
		return "file://" + url.substr(o.length()).uri_decode()
	return url


func _is_remote_allowed(url: String) -> bool:
	if not (url.begins_with("http://") or url.begins_with("https://")) or url.contains("/../"):
		return false
	for root in _remote_roots:
		if url.begins_with(root):
			return true
	return false


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
			_clients.erase(c)
			if _respond(peer, text.get_slice("\r\n", 0)):
				peer.disconnect_from_host()


## Answers a request. Returns false when the answer comes later (proxied
## files are fetched first); that path closes the connection itself.
func _respond(peer: StreamPeerTCP, request_line: String) -> bool:
	var parts := request_line.split(" ")
	var target := parts[1].get_slice("?", 0).get_slice("#", 0) if parts.size() >= 2 else ""
	var prefix := "/" + _token + "/"
	var ruffle_prefix := prefix + RUFFLE_DIR + "/"
	# Ruffle is fetched cross-origin by pages from any world (even https ones:
	# Chromium treats loopback as secure), so answer CORS / private-network
	# preflights for it.
	if parts.size() >= 2 and parts[0] == "OPTIONS" and target.begins_with(ruffle_prefix):
		_send(peer, 204, "text/plain", PackedByteArray(), true)
		return true
	if parts.size() < 2 or not (parts[0] == "GET" or parts[0] == "HEAD"):
		_send(peer, 405, "text/plain", "Method not allowed".to_utf8_buffer())
		return true
	# OpenQBORG's own helper pages (e.g. swf.html for SWF surfaces).
	if target.begins_with(prefix + OQB_DIR + "/"):
		var page := target.substr((prefix + OQB_DIR + "/").length())
		if page.begins_with("inline/") and _inline.has(page.trim_prefix("inline/")):
			_send(peer, 200, "text/html; charset=utf-8", (_inline[page.trim_prefix("inline/")] as String).to_utf8_buffer(), true)
			return true
		if not page in OQB_PAGES:
			_send(peer, 404, "text/plain", "Not found".to_utf8_buffer(), true)
			return true
		_send(peer, 200, "text/html", FileAccess.get_file_as_bytes("res://web/" + page), true)
		return true
	if target.begins_with(ruffle_prefix):
		# Served from the player's own resources, so this works in exports too.
		var file := target.substr(ruffle_prefix.length()).uri_decode()
		var res := "res://web/ruffle/" + file.get_file()
		if file.contains("/") or not FileAccess.file_exists(res):
			_send(peer, 404, "text/plain", "Not found".to_utf8_buffer(), true)
			return true
		var data := FileAccess.get_file_as_bytes(res) if parts[0] == "GET" else PackedByteArray()
		_send(peer, 200, MIME.get(file.get_extension().to_lower(), "application/octet-stream"), data, true)
		return true
	var remote_prefix := prefix + REMOTE_DIR + "/"
	if target.begins_with(remote_prefix):
		var rest := target.substr(remote_prefix.length())
		var url := rest.get_slice("/", 0) + "://" + rest.substr(rest.find("/") + 1)
		if rest.find("/") < 0 or fetcher == null or not _is_remote_allowed(url):
			_send(peer, 403, "text/plain", "Forbidden".to_utf8_buffer())
			return true
		_proxy(peer, url, parts[0] == "HEAD")
		return false
	if not target.begins_with(prefix):
		_send(peer, 404, "text/plain", "Not found".to_utf8_buffer())
		return true
	var path := BorgUrl.normalize("/" + target.substr(prefix.length()).uri_decode())
	if not _is_allowed(path):
		_send(peer, 403, "text/plain", "Forbidden".to_utf8_buffer())
		return true
	path = BorgUrl.resolve_case(path)
	if DirAccess.dir_exists_absolute(path):
		path = BorgUrl.resolve_case(path.path_join("index.html"))
	if not FileAccess.file_exists(path):
		_send(peer, 404, "text/plain", "Not found".to_utf8_buffer())
		return true
	var body := FileAccess.get_file_as_bytes(path) if parts[0] == "GET" else PackedByteArray()
	_send(peer, 200, MIME.get(path.get_extension().to_lower(), "application/octet-stream"), body)
	return true


## Sends a remote file once the fetcher has it (from its caches, or the
## network with retries). 503 when the server was only busy, so the page
## view tries again.
func _proxy(peer: StreamPeerTCP, url: String, head_only: bool) -> void:
	var body := await fetcher.fetch(url)
	if body.is_empty():
		var code := 503 if fetcher.failed.has(url) else 404
		_send(peer, code, "text/plain", "Not available".to_utf8_buffer())
	else:
		var mime: String = MIME.get(url.get_extension().to_lower(), "application/octet-stream")
		_send(peer, 200, mime, PackedByteArray() if head_only else body)
	peer.disconnect_from_host()


func _send(peer: StreamPeerTCP, code: int, mime: String, body: PackedByteArray, shared := false) -> void:
	var reason: String = {200: "OK", 204: "No Content", 403: "Forbidden", 404: "Not Found",
			405: "Method Not Allowed", 503: "Service Unavailable"}.get(code, "")
	var cors := ""
	if shared:
		cors = "Access-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: GET, HEAD, OPTIONS\r\n" \
				+ "Access-Control-Allow-Headers: *\r\nAccess-Control-Allow-Private-Network: true\r\n" \
				+ "Cross-Origin-Resource-Policy: cross-origin\r\n"
	var head := "HTTP/1.1 %d %s\r\nContent-Type: %s\r\nContent-Length: %d\r\nCache-Control: no-cache\r\n%sConnection: close\r\n\r\n" \
			% [code, reason, mime, body.size(), cors]
	peer.set_no_delay(true)
	peer.put_data(head.to_ascii_buffer())
	var sent := 0
	while sent < body.size():
		var chunk := body.slice(sent, mini(sent + 65536, body.size()))
		var err := peer.put_data(chunk)
		if err != OK:
			return
		sent += chunk.size()
