class_name BorgFetcher
extends Node
## Fetches world files from disk (file://) or the network (http/https).
## borgs:// worlds arrive here as https:// and are verified against the system
## CA store; a bad certificate is a hard failure, never a silent downgrade.

const MAX_PARALLEL := 6
const TIMEOUT_SEC := 30.0

var last_error := ""
var _cache := {}
var _active := 0


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
		data = await _fetch_http(url)
	if not data.is_empty():
		_cache[url] = data
	return data


func fetch_text(url: String) -> String:
	return (await fetch(url)).get_string_from_utf8()


func clear_cache() -> void:
	_cache.clear()


func _fetch_http(url: String) -> PackedByteArray:
	while _active >= MAX_PARALLEL:
		await get_tree().process_frame
	_active += 1
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
		elif code >= 400:
			last_error = "HTTP %d: %s" % [code, url]
		else:
			body = res[3]
	req.queue_free()
	_active -= 1
	return body
