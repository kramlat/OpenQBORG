# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 Mark Toman and OpenQBORG contributors
class_name BorgFetcher
extends Node
## Fetches world files from disk (file://) or the network (http/https).
## borgs:// worlds arrive here as https:// and are verified against the system
## CA store; a bad certificate is a hard failure, never a silent downgrade.

const MAX_PARALLEL := 6
## Archives throttle hard (the Wayback Machine refuses connections when a
## client opens many at once), so be gentle with them.
const HOST_LIMITS := {"web.archive.org": 2}
const TIMEOUT_SEC := 30.0
## Refused connections, 429 and 5xx are retried this many times, backing off.
const RETRIES := 4
## Archived snapshots never change, so they are kept on disk: revisiting an
## online world costs nothing, and a load cut short by throttling carries on
## where it stopped next time.
const ARCHIVE_HOSTS := ["web.archive.org"]
const DISK_CACHE := "user://archive_cache"

var last_error := ""
var _cache := {}
var _active := 0
var _active_by_host := {}
## host -> Time.get_ticks_msec() before which nothing is sent to it (after a
## refusal or a 429, every request to that host waits, not just the one).
var _host_resume := {}


func fetch(url: String) -> PackedByteArray:
	if _cache.has(url):
		return _cache[url]
	var data := PackedByteArray()
	if BorgUrl.is_local(url):
		var path := BorgUrl.resolve_case(BorgUrl.local_path(url))
		if FileAccess.file_exists(path):
			data = FileAccess.get_file_as_bytes(path)
		else:
			last_error = "Not found: " + path
	else:
		var disk := _disk_path(url)
		if not disk.is_empty() and FileAccess.file_exists(disk):
			data = FileAccess.get_file_as_bytes(disk)
		else:
			data = await _fetch_http(url)
			if not disk.is_empty() and not data.is_empty():
				DirAccess.make_dir_recursive_absolute(DISK_CACHE)
				var f := FileAccess.open(disk, FileAccess.WRITE)
				if f != null:
					f.store_buffer(data)
	if not data.is_empty():
		_cache[url] = data
	return data


func fetch_text(url: String) -> String:
	return (await fetch(url)).get_string_from_utf8()


func clear_cache() -> void:
	_cache.clear()


## Where an archived URL is kept on disk ("" if it isn't an archive URL).
static func _disk_path(url: String) -> String:
	var host := _host_of(url)
	if not host in ARCHIVE_HOSTS:
		return ""
	return DISK_CACHE.path_join(url.sha256_text())


static func _host_of(url: String) -> String:
	return url.get_slice("//", 1).get_slice("/", 0).get_slice(":", 0).to_lower()


func _fetch_http(url: String) -> PackedByteArray:
	var host := _host_of(url)
	var limit: int = HOST_LIMITS.get(host, MAX_PARALLEL)
	var body := PackedByteArray()
	for attempt in RETRIES + 1:
		while _active >= MAX_PARALLEL or _active_by_host.get(host, 0) >= limit \
				or Time.get_ticks_msec() < _host_resume.get(host, 0):
			await get_tree().process_frame
		_active += 1
		_active_by_host[host] = _active_by_host.get(host, 0) + 1
		var r := await _request_once(url)
		_active -= 1
		_active_by_host[host] -= 1
		body = r.body
		if not r.retry or attempt == RETRIES:
			break
		# 1, 2, 4, 8 s (or the server's Retry-After): give a throttling server room.
		var wait_ms: int = r.wait_ms if r.wait_ms > 0 else int(1000 * pow(2.0, attempt))
		_host_resume[host] = maxi(_host_resume.get(host, 0), Time.get_ticks_msec() + wait_ms)
	return body


## One request: {body, retry, wait_ms} (retry when it's worth trying again,
## wait_ms from a Retry-After header).
func _request_once(url: String) -> Dictionary:
	var retry := false
	var wait_ms := 0
	var req := HTTPRequest.new()
	req.timeout = TIMEOUT_SEC
	req.accept_gzip = true
	add_child(req)
	if url.begins_with("https://"):
		req.set_tls_options(TLSOptions.client())
	var err := req.request(url, PackedStringArray(["User-Agent: OpenQBORG/0.1"]))
	var body := PackedByteArray()
	if err != OK:
		last_error = "Request failed (%s): %s" % [error_string(err), url]
	else:
		var res: Array = await req.request_completed
		var result: int = res[0]
		var code: int = res[1]
		if result == HTTPRequest.RESULT_TLS_HANDSHAKE_ERROR:
			last_error = "TLS handshake failed (certificate not trusted?): " + url
		elif result != HTTPRequest.RESULT_SUCCESS:
			last_error = "Network error %d: %s" % [result, url]
			retry = result in [HTTPRequest.RESULT_CANT_CONNECT, HTTPRequest.RESULT_CONNECTION_ERROR,
					HTTPRequest.RESULT_NO_RESPONSE]
		elif code >= 400:
			last_error = "HTTP %d: %s" % [code, url]
			retry = code == 429 or code >= 500
			for h: String in res[2]:
				var value := h.get_slice(":", 1).strip_edges()
				if h.to_lower().begins_with("retry-after:") and value.is_valid_int():
					wait_ms = mini(60, value.to_int()) * 1000
		else:
			body = res[3]
	req.queue_free()
	return {"body": body, "retry": retry, "wait_ms": wait_ms}
