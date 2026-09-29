// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (c) 2026 Mark Toman and OpenQBORG contributors
// Feeding FFmpeg from a Godot PackedByteArray instead of a file.
#pragma once

#include <godot_cpp/variant/string.hpp>

#include <algorithm>
#include <cstdint>
#include <cstring>

extern "C" {
#include <libavformat/avformat.h>
#include <libavutil/error.h>
}

namespace oqb {

struct MemoryReader {
	const uint8_t *data = nullptr;
	int64_t size = 0;
	int64_t pos = 0;
};

inline int read_packet(void *opaque, uint8_t *buf, int buf_size) {
	auto *r = static_cast<MemoryReader *>(opaque);
	int64_t left = r->size - r->pos;
	if (left <= 0) {
		return AVERROR_EOF;
	}
	int n = static_cast<int>(std::min<int64_t>(buf_size, left));
	std::memcpy(buf, r->data + r->pos, n);
	r->pos += n;
	return n;
}

inline int64_t seek(void *opaque, int64_t offset, int whence) {
	auto *r = static_cast<MemoryReader *>(opaque);
	if (whence == AVSEEK_SIZE) {
		return r->size;
	}
	int64_t base = 0;
	switch (whence & ~AVSEEK_FORCE) {
		case SEEK_SET: base = 0; break;
		case SEEK_CUR: base = r->pos; break;
		case SEEK_END: base = r->size; break;
		default: return -1;
	}
	int64_t target = base + offset;
	if (target < 0 || target > r->size) {
		return -1;
	}
	r->pos = target;
	return target;
}

inline godot::String av_error(int err) {
	char buf[AV_ERROR_MAX_STRING_SIZE] = {};
	av_strerror(err, buf, sizeof(buf));
	return godot::String(buf);
}

// Opens `reader` as an FFmpeg input with custom I/O. On success returns 0 and
// sets *fmt and *io; the caller frees them with close_input().
inline int open_input(MemoryReader *reader, AVFormatContext **fmt, AVIOContext **io) {
	constexpr int IO_BUFFER_SIZE = 32 * 1024;
	auto *buffer = static_cast<uint8_t *>(av_malloc(IO_BUFFER_SIZE));
	*io = avio_alloc_context(buffer, IO_BUFFER_SIZE, 0, reader, read_packet, nullptr, seek);
	if (!*io) {
		av_free(buffer);
		return AVERROR(ENOMEM);
	}
	*fmt = avformat_alloc_context();
	(*fmt)->pb = *io;
	(*fmt)->flags |= AVFMT_FLAG_CUSTOM_IO;
	return avformat_open_input(fmt, nullptr, nullptr, nullptr);
}

inline void close_input(AVFormatContext **fmt, AVIOContext **io) {
	avformat_close_input(fmt);
	if (*io) {
		av_freep(&(*io)->buffer);
		avio_context_free(io);
	}
}

} // namespace oqb
