# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 Mark Toman and OpenQBORG contributors
class_name BorgUrl
extends RefCounted
## URL handling for QBORG worlds.
##
##   borg://host/path.borg   -> http://host:80/path.borg
##   borgs://host/path.borg  -> https://host:443/path.borg
##   /abs/path.borg, file:///abs/path.borg -> local file
##
## borg:// is also the command channel CYBERWORLD pages used to talk to the
## 3D view (see html/scripts/player.js in the original worlds):
##   borg://cmd.prev         -> go back to the previous world
##   borg://cmd.web@<url>    -> show <url> as a 2D page
##   borg://<dir>/x.borg     -> pushTo3D(); for pages loaded from file:// the
##                              "host" is really a local path minus its "/".

enum Kind { WORLD, COMMAND_PREV, COMMAND_WEB, INVALID }


## Classifies a borg:// (or plain) URL coming from the address bar or a page.
## Returns {kind: Kind, url: String} where url is fetchable (http/https/file).
static func classify(input: String, context_url := "") -> Dictionary:
	var s := input.strip_edges()
	if s.is_empty():
		return {"kind": Kind.INVALID, "url": ""}
	var lower := s.to_lower()
	if lower.begins_with("borg://cmd.prev"):
		return {"kind": Kind.COMMAND_PREV, "url": ""}
	if lower.begins_with("borg://cmd.web@") or lower.begins_with("borgs://cmd.web@"):
		return {"kind": Kind.COMMAND_WEB, "url": s.substr(s.find("@") + 1)}
	return {"kind": Kind.WORLD, "url": to_fetchable(s, context_url)}


## Maps borg/borgs/bare input to an http(s):// or file:// URL.
static func to_fetchable(input: String, context_url := "") -> String:
	var s := input.strip_edges()
	var lower := s.to_lower()
	if lower.begins_with("borgs://"):
		return normalize("https://" + s.substr(8))
	if lower.begins_with("borg://"):
		var rest := s.substr(7)
		# pushTo3D() from a file:// page produces borg://home/user/world/x.borg.
		if is_local(context_url) or rest.begins_with("/"):
			var local := normalize("/" + rest.trim_prefix("/"))
			if FileAccess.file_exists(resolve_case(local)):
				return "file://" + local
		# Pages only know "borg://"; never downgrade a world served over TLS.
		var scheme := "https://" if context_url.to_lower().begins_with("https://") else "http://"
		return normalize(scheme + rest)
	if lower.begins_with("http://") or lower.begins_with("https://") or lower.begins_with("file://"):
		return normalize(s)
	if s.begins_with("~"):
		return "file://" + normalize(OS.get_environment("HOME") + s.substr(1))
	if s.begins_with("/"):
		return "file://" + normalize(s)
	if s.begins_with("."):
		return "file://" + normalize(OS.get_environment("PWD").path_join(s))
	# Bare "host/path.borg" from the address bar.
	return normalize("http://" + s)


## The borg:// form shown in the address bar.
static func to_display(url: String) -> String:
	if url.begins_with("https://"):
		return "borgs://" + url.substr(8)
	if url.begins_with("http://"):
		return "borg://" + url.substr(7)
	return url.trim_prefix("file://")


static func is_local(url: String) -> bool:
	return url.begins_with("file://") or url.begins_with("/")


static func local_path(url: String) -> String:
	return url.trim_prefix("file://").uri_decode()


## Directory part of a URL, with trailing slash.
static func dir_of(url: String) -> String:
	var q := url.find("?")
	if q >= 0:
		url = url.left(q)
	return url.left(url.rfind("/") + 1)


## Resolves a relative reference against a base directory URL.
static func join(base_dir: String, rel: String) -> String:
	var lower := rel.to_lower()
	if lower.contains("://"):
		return normalize(rel)
	if rel.begins_with("/"):
		var origin_end := base_dir.find("/", base_dir.find("://") + 3)
		if base_dir.begins_with("file://") or origin_end < 0:
			return normalize("file://" + rel) if base_dir.begins_with("file://") else normalize(base_dir + rel)
		return normalize(base_dir.left(origin_end) + rel)
	return normalize(base_dir + rel.replace("\\", "/"))


## Collapses "." and ".." segments. Leaves scheme and host alone.
static func normalize(url: String) -> String:
	var prefix := ""
	var path := url
	var scheme_end := url.find("://")
	if scheme_end >= 0:
		var host_start := scheme_end + 3
		var path_start := url.find("/", host_start)
		if url.begins_with("file://"):
			path_start = host_start
		if path_start < 0:
			return url + "/"
		prefix = url.left(path_start)
		path = url.substr(path_start)
	var absolute := path.begins_with("/")
	var out: PackedStringArray = []
	for seg in path.split("/"):
		if seg == "" or seg == ".":
			continue
		if seg == "..":
			if out.size() > 0:
				out.remove_at(out.size() - 1)
			continue
		out.append(seg)
	var joined := "/".join(out)
	if path.ends_with("/") and not joined.is_empty():
		joined += "/"
	return prefix + ("/" if absolute else "") + joined


## Finds a local file ignoring case: worlds were authored on Windows and their
## references rarely match on-disk case ("Articunos.flr" vs "articunos.flr").
static func resolve_case(path: String) -> String:
	if path.is_empty() or FileAccess.file_exists(path) or DirAccess.dir_exists_absolute(path):
		return path
	var parts := path.split("/")
	var current := "/" if path.begins_with("/") else ""
	for i in parts.size():
		var part := parts[i]
		if part.is_empty():
			continue
		var candidate := current.path_join(part) if current != "" else part
		if not (FileAccess.file_exists(candidate) or DirAccess.dir_exists_absolute(candidate)):
			var found := ""
			var dir := DirAccess.open(current if current != "" else ".")
			if dir != null:
				dir.include_hidden = true
				for entry in dir.get_files() + dir.get_directories():
					if entry.to_lower() == part.to_lower():
						found = entry
						break
			if found.is_empty():
				return path
			candidate = current.path_join(found) if current != "" else found
		current = candidate
	return current


## Parses a Windows Internet Shortcut (.url) as used by gtw/gtw2/gtw3 links.
## Returns {url, target} where url is still relative ("http://../html/x.html"
## really means "../html/x.html" next to the domains/ folder).
static func parse_shortcut(text: String) -> Dictionary:
	var result := {"url": "", "target": ""}
	for line in text.split("\n"):
		line = line.strip_edges()
		if line.to_upper().begins_with("URL="):
			result.url = line.substr(4)
		elif line.to_upper().begins_with("TARGET="):
			result.target = line.substr(7).trim_prefix('"').trim_suffix('"')
	return result


## Resolves a shortcut's URL= value against the world's domains/ directory.
static func resolve_shortcut_target(raw: String, domains_dir: String) -> String:
	var lower := raw.to_lower()
	var rest := raw
	if lower.begins_with("file:///"):
		rest = raw.substr(8)
	elif lower.begins_with("http://"):
		rest = raw.substr(7)
	elif lower.begins_with("https://"):
		return normalize(raw)
	else:
		return join(domains_dir, raw)
	# "http://../html/x.html" is a relative link the old tools wrote;
	# "http://www.cwarp.com/" is a genuine web address.
	if rest.begins_with(".") or rest.begins_with("/") or not rest.get_slice("/", 0).contains("."):
		return join(domains_dir, rest)
	return normalize(raw)
