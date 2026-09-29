# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 Mark Toman and OpenQBORG contributors
class_name BorgFrames
extends RefCounted
## A picture with one or more frames: floor/ceiling tile images, wall strips,
## backdrops and emblems can be animated GIFs (as the original browser
## allowed), APNGs or Motion JPEGs (raw, AVI, MOV, multipart). Every frame is
## a full image; `delays` holds each frame's duration in milliseconds.
##
## Static PNG/JPEG/BMP/WebP load through Godot. GIFs (static or animated),
## APNG animation and MJPEG need the OpenQBORG media extension (FFmpeg);
## without it an APNG shows its first frame and GIFs don't load.

const MAX_FRAMES := 256

var images: Array[Image] = []
var delays := PackedInt32Array()
var total_ms := 0


func is_animated() -> bool:
	return images.size() > 1 and total_ms > 0


func first() -> Image:
	return images[0] if not images.is_empty() else null


## Index of the frame showing `ms` milliseconds into the (looping) animation.
func frame_at(ms: float) -> int:
	if not is_animated():
		return 0
	var t := fmod(ms, float(total_ms))
	for i in delays.size():
		t -= delays[i]
		if t < 0.0:
			return i
	return delays.size() - 1


static func has_decoder() -> bool:
	return ClassDB.class_exists("FFmpegFrameDecoder")


## "gif", "apng", "mjpeg", "video" (AVI/MOV/MP4/multipart), "image" (static,
## Godot reads it) or "" (unknown).
static func sniff(bytes: PackedByteArray) -> String:
	if bytes.size() < 12:
		return ""
	var head := bytes.slice(0, 12)
	if head.slice(0, 4).get_string_from_ascii() == "GIF8":
		return "gif"
	if head[0] == 0x89 and head[1] == 0x50:
		return "apng" if _png_has_actl(bytes) else "image"
	if head[0] == 0xff and head[1] == 0xd8:
		return "mjpeg" if _jpeg_is_sequence(bytes) else "image"
	if head.slice(0, 4).get_string_from_ascii() == "RIFF":
		var form := head.slice(8, 12).get_string_from_ascii()
		return "video" if form.begins_with("AVI") else ("image" if form == "WEBP" else "")
	if head.slice(4, 8).get_string_from_ascii() in ["ftyp", "moov", "mdat", "wide"]:
		return "video"
	if head[0] == 0x42 and head[1] == 0x4d:
		return "image"
	if head.slice(0, 2).get_string_from_ascii() == "--":
		return "video" # multipart/x-mixed-replace JPEG stream
	return ""


static func decode(bytes: PackedByteArray) -> BorgFrames:
	var kind := sniff(bytes)
	var f := BorgFrames.new()
	if kind == "image" or (kind == "apng" and not has_decoder()):
		var img := BorgWorld.decode_image(bytes)
		if img == null:
			return null
		f.images.append(img)
		f.delays.append(0)
		return f
	if kind.is_empty() or not has_decoder():
		return null
	var r: Dictionary = ClassDB.class_call_static("FFmpegFrameDecoder", "decode_frames", bytes, MAX_FRAMES,
			64 * 1024 * 1024)
	if not r.get("ok", false):
		return null
	var w: int = r.width
	var h: int = r.height
	for data in r.frames:
		f.images.append(Image.create_from_data(w, h, false, Image.FORMAT_RGBA8, data))
	f.delays = r.delays_ms
	for d in f.delays:
		f.total_ms += d
	return f


## APNG = a PNG with an acTL chunk before the first IDAT.
static func _png_has_actl(bytes: PackedByteArray) -> bool:
	var o := 8
	while o + 8 <= bytes.size():
		var length := (bytes[o] << 24) | (bytes[o + 1] << 16) | (bytes[o + 2] << 8) | bytes[o + 3]
		var type := bytes.slice(o + 4, o + 8).get_string_from_ascii()
		if type == "acTL":
			return true
		if type == "IDAT" or type == "IEND":
			return false
		o += 12 + length
	return false


## Motion JPEG (raw): another JPEG starts right after the first one's EOI.
## Walks the segments properly so embedded EXIF thumbnails don't count.
static func _jpeg_is_sequence(bytes: PackedByteArray) -> bool:
	var o := 2
	var n := bytes.size()
	while o + 4 <= n:
		if bytes[o] != 0xff:
			return false
		var marker := bytes[o + 1]
		if marker == 0xd9: # EOI
			o += 2
			break
		if marker == 0xda: # SOS: skip entropy-coded data up to the next marker
			o += 2 + ((bytes[o + 2] << 8) | bytes[o + 3])
			while o + 1 < n:
				if bytes[o] == 0xff and bytes[o + 1] != 0x00 and not (bytes[o + 1] >= 0xd0 and bytes[o + 1] <= 0xd7):
					break
				o += 1
			continue
		if marker == 0xd8 or (marker >= 0xd0 and marker <= 0xd7) or marker == 0x01:
			o += 2
			continue
		o += 2 + ((bytes[o + 2] << 8) | bytes[o + 3])
	# Skip padding, then look for another SOI.
	while o < n and bytes[o] != 0xff:
		o += 1
	return o + 2 < n and bytes[o] == 0xff and bytes[o + 1] == 0xd8
