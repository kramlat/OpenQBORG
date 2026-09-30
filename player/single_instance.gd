# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 Mark Toman and OpenQBORG contributors
class_name SingleInstance
extends Node
## One player window per user: a second launch (a borg:// link, a .borg file
## opened from the desktop) hands its address to the running player, which
## opens it in a new tab, and quits.
##
## The running player listens on a random loopback port. The port and a
## random token are in a file only this user can read; a handoff must present
## the token, so other local users can't push addresses into the player.

## Another launch handed over `url` ("" for a plain launch: a new empty tab).
signal url_received(url: String)

const INFO := "user://instance.cfg"
const HANDOFF_TIMEOUT_MS := 1500

var _server := TCPServer.new()
var _token := ""
var _clients: Array[Dictionary] = []


## Tries to hand `url` to a running player. True when one took it.
static func hand_off(url: String) -> bool:
	var cfg := ConfigFile.new()
	if cfg.load(INFO) != OK:
		return false
	var port: int = cfg.get_value("instance", "port", 0)
	var token: String = cfg.get_value("instance", "token", "")
	if port <= 0 or token.is_empty():
		return false
	var peer := StreamPeerTCP.new()
	if peer.connect_to_host("127.0.0.1", port) != OK:
		return false
	var deadline := Time.get_ticks_msec() + HANDOFF_TIMEOUT_MS
	var sent := false
	var reply := ""
	while Time.get_ticks_msec() < deadline:
		peer.poll()
		var status := peer.get_status()
		if status == StreamPeerTCP.STATUS_ERROR or status == StreamPeerTCP.STATUS_NONE:
			return false # stale file: nobody is listening
		if status == StreamPeerTCP.STATUS_CONNECTED:
			if not sent:
				peer.put_data((token + "\n" + url.uri_encode() + "\n").to_utf8_buffer())
				sent = true
			var avail := peer.get_available_bytes()
			if avail > 0:
				reply += peer.get_utf8_string(avail)
				if reply.begins_with("ok"):
					peer.disconnect_from_host()
					return true
		OS.delay_msec(10)
	peer.disconnect_from_host()
	return false


## Hands every address over (a plain launch hands over "", for a new empty
## tab). True when a running player took them.
static func hand_off_all(urls: PackedStringArray) -> bool:
	if urls.is_empty():
		return hand_off("")
	for url in urls:
		if not hand_off(url):
			return false
	return true


## Becomes the running player: listen, and say where.
func start() -> void:
	_token = Crypto.new().generate_random_bytes(16).hex_encode()
	for attempt in 20:
		if _server.listen(randi_range(20000, 60000), "127.0.0.1") == OK:
			break
	if not _server.is_listening():
		return
	var cfg := ConfigFile.new()
	cfg.set_value("instance", "port", _server.get_local_port())
	cfg.set_value("instance", "token", _token)
	cfg.set_value("instance", "pid", OS.get_process_id())
	if cfg.save(INFO) == OK:
		FileAccess.set_unix_permissions(ProjectSettings.globalize_path(INFO),
				FileAccess.UNIX_READ_OWNER | FileAccess.UNIX_WRITE_OWNER)


## Removes the file on exit, unless a newer player has taken over.
func stop() -> void:
	if not _server.is_listening():
		return
	_server.stop()
	var cfg := ConfigFile.new()
	if cfg.load(INFO) == OK and cfg.get_value("instance", "token", "") == _token:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(INFO))


func _exit_tree() -> void:
	stop()


func _process(_delta: float) -> void:
	while _server.is_connection_available():
		_clients.append({"peer": _server.take_connection(), "buf": "", "t": Time.get_ticks_msec()})
	for c in _clients.duplicate():
		var peer: StreamPeerTCP = c.peer
		peer.poll()
		if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED or Time.get_ticks_msec() - c.t > 5000:
			_clients.erase(c)
			continue
		var avail := peer.get_available_bytes()
		if avail > 0:
			c.buf += peer.get_utf8_string(avail)
		var lines: PackedStringArray = str(c.buf).split("\n")
		if lines.size() < 3:
			continue # token and address not complete yet
		_clients.erase(c)
		if lines[0] == _token:
			peer.put_data("ok\n".to_utf8_buffer())
			url_received.emit(lines[1].uri_decode())
		peer.disconnect_from_host()
