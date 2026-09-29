// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (c) 2026 Mark Toman and OpenQBORG contributors
#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>

namespace godot {

// Decodes a whole in-memory audio file with FFmpeg into 16-bit PCM.
// GDScript wraps the result in an AudioStreamWAV (see borg_audio.gd).
class FFmpegAudioDecoder : public RefCounted {
	GDCLASS(FFmpegAudioDecoder, RefCounted)

protected:
	static void _bind_methods();

public:
	// Returns {ok: bool, error: String, mix_rate: int, stereo: bool,
	//          data: PackedByteArray (s16le interleaved), codec: String}.
	// Decoding stops after max_seconds (0 = no limit).
	static Dictionary decode(const PackedByteArray &bytes, double max_seconds);
	static String ffmpeg_version();
};

} // namespace godot
