# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 Mark Toman and OpenQBORG contributors
class_name BorgAudio
extends RefCounted
## Turns audio file bytes into an AudioStream.
##
## Godot decodes WAV (PCM), Ogg Vorbis and MP3 itself. Everything else — AAC
## (.aac/.m4a/.mp4), Opus (.opus/.oga), FLAC, ALAC, WMA, AIFF, WebM/Matroska
## audio, ADPCM or mu-law WAV, ... — goes through the OpenQBORG audio
## GDExtension (FFmpeg, addons/openqborg_media) when it is installed.

## File extensions worth offering in pickers. The real format is sniffed from
## the bytes, never trusted from the name.
const EXTENSIONS := ["wav", "ogg", "oga", "opus", "mp3", "aac", "m4a", "mp4", "flac",
		"aif", "aiff", "wma", "webm", "mka", "caf", "mid", "midi"]

## Longest sound decoded to PCM in one go (10 minutes).
const MAX_SECONDS := 600.0

static var last_error := ""


static func has_ffmpeg() -> bool:
	return ClassDB.class_exists("FFmpegAudioDecoder")


static func is_midi(bytes: PackedByteArray) -> bool:
	return bytes.size() >= 4 and bytes.slice(0, 4).get_string_from_ascii() == "MThd"


## Best-effort container/codec sniff: "wav", "vorbis", "mp3", "midi" or
## "other" (left to FFmpeg).
static func sniff(bytes: PackedByteArray) -> String:
	if bytes.size() < 12:
		return "other"
	var head := bytes.slice(0, 4).get_string_from_ascii()
	if head == "MThd":
		return "midi"
	if head == "RIFF" and bytes.slice(8, 12).get_string_from_ascii() == "WAVE":
		# Godot reads PCM (1) and IEEE float (3); ADPCM, mu-law etc. go to FFmpeg.
		var fmt := _wav_format(bytes)
		return "wav" if fmt == 1 or fmt == 3 or fmt == 0xfffe else "other"
	if head == "OggS":
		# Vorbis identification header (0x01 "vorbis") in the first page;
		# Ogg can also carry Opus, FLAC or Speex, which go to FFmpeg.
		var first_page := bytes.slice(0, mini(bytes.size(), 128)).hex_encode()
		return "vorbis" if first_page.contains("01766f72626973") else "other"
	if head.begins_with("ID3"):
		return "mp3"
	# MPEG audio frame sync. Layer bits 00 mean ADTS AAC, not MP3.
	if bytes[0] == 0xff and (bytes[1] & 0xe0) == 0xe0 and (bytes[1] & 0x06) != 0:
		return "mp3"
	return "other"


## Decodes `bytes` (name is only used in messages). Returns null on failure
## and sets last_error. MIDI is not handled here; see BorgMusic.
static func decode(bytes: PackedByteArray, name := "") -> AudioStream:
	last_error = ""
	var stream: AudioStream = null
	match sniff(bytes):
		"midi":
			last_error = name + " is MIDI"
			return null
		"wav":
			stream = AudioStreamWAV.load_from_buffer(bytes)
		"vorbis":
			stream = AudioStreamOggVorbis.load_from_buffer(bytes)
		"mp3":
			var mp3 := AudioStreamMP3.new()
			mp3.data = bytes
			stream = mp3 if mp3.get_length() > 0.0 else null
	if stream == null:
		stream = _decode_ffmpeg(bytes, name)
	return stream


static func _decode_ffmpeg(bytes: PackedByteArray, name: String) -> AudioStream:
	if not has_ffmpeg():
		last_error = "%s: this format needs the OpenQBORG media extension (tools/build-media-ext.sh)" % name
		return null
	var r: Dictionary = ClassDB.class_call_static("FFmpegAudioDecoder", "decode", bytes, MAX_SECONDS)
	if not r.get("ok", false):
		last_error = "%s: %s" % [name, r.get("error", "decode failed")]
		return null
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = r.mix_rate
	wav.stereo = r.stereo
	wav.data = r.data
	return wav


## Makes a stream loop forever (sound tiles, music regions).
static func set_looping(stream: AudioStream) -> void:
	if stream is AudioStreamWAV:
		var wav := stream as AudioStreamWAV
		wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
		wav.loop_begin = 0
		var frame_bytes := (2 if wav.format == AudioStreamWAV.FORMAT_16_BITS else 1) * (2 if wav.stereo else 1)
		if wav.format == AudioStreamWAV.FORMAT_16_BITS or wav.format == AudioStreamWAV.FORMAT_8_BITS:
			wav.loop_end = wav.data.size() / frame_bytes
		else:
			wav.loop_end = int(wav.get_length() * wav.mix_rate)
	elif stream is AudioStreamOggVorbis:
		(stream as AudioStreamOggVorbis).loop = true
	elif stream is AudioStreamMP3:
		(stream as AudioStreamMP3).loop = true


## WAVE format tag from the "fmt " chunk (1 = PCM, 3 = float, 0xfffe =
## extensible), or -1.
static func _wav_format(bytes: PackedByteArray) -> int:
	var o := 12
	while o + 10 <= bytes.size():
		var id := bytes.slice(o, o + 4).get_string_from_ascii()
		var size := bytes.decode_u32(o + 4)
		if id == "fmt ":
			return bytes.decode_u16(o + 8)
		o += 8 + size + (size & 1)
	return -1
