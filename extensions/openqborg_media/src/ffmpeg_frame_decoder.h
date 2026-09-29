// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (c) 2026 Mark Toman and OpenQBORG contributors
#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>

namespace godot {

// Decodes every frame of an in-memory animated image or video (animated
// GIF, APNG, Motion JPEG in raw/AVI/MOV/multipart form, ...) to RGBA8.
// Also reads plain GIFs, which Godot can't load itself.
class FFmpegFrameDecoder : public RefCounted {
	GDCLASS(FFmpegFrameDecoder, RefCounted)

protected:
	static void _bind_methods();

public:
	// Returns {ok, error, width, height, frames: Array[PackedByteArray RGBA8],
	//          delays_ms: PackedInt32Array, codec}. Stops after max_frames
	// frames or max_pixels pixels in total, whichever comes first.
	static Dictionary decode_frames(const PackedByteArray &bytes, int64_t max_frames, int64_t max_pixels);
};

} // namespace godot
