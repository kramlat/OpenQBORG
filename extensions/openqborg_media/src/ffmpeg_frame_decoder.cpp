// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (c) 2026 Mark Toman and OpenQBORG contributors
#include "ffmpeg_frame_decoder.h"
#include "memory_io.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>

#include <cmath>

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/imgutils.h>
#include <libswscale/swscale.h>
}

using namespace godot;

namespace {

constexpr int DEFAULT_DELAY_MS = 100;

struct Session {
	oqb::MemoryReader reader;
	AVIOContext *io = nullptr;
	AVFormatContext *fmt = nullptr;
	AVCodecContext *codec = nullptr;
	SwsContext *sws = nullptr;
	AVPacket *packet = nullptr;
	AVFrame *frame = nullptr;

	~Session() {
		av_frame_free(&frame);
		av_packet_free(&packet);
		sws_freeContext(sws);
		avcodec_free_context(&codec);
		oqb::close_input(&fmt, &io);
	}
};

Dictionary failure(const String &why) {
	Dictionary d;
	d["ok"] = false;
	d["error"] = why;
	return d;
}

} // namespace

void FFmpegFrameDecoder::_bind_methods() {
	ClassDB::bind_static_method("FFmpegFrameDecoder",
			D_METHOD("decode_frames", "bytes", "max_frames", "max_pixels"),
			&FFmpegFrameDecoder::decode_frames, DEFVAL(256), DEFVAL(64 * 1024 * 1024));
}

Dictionary FFmpegFrameDecoder::decode_frames(const PackedByteArray &bytes, int64_t max_frames, int64_t max_pixels) {
	if (bytes.is_empty()) {
		return failure("empty input");
	}
	Session s;
	s.reader.data = bytes.ptr();
	s.reader.size = bytes.size();
	int err = oqb::open_input(&s.reader, &s.fmt, &s.io);
	if (err < 0) {
		return failure("unrecognised image/video: " + oqb::av_error(err));
	}
	if ((err = avformat_find_stream_info(s.fmt, nullptr)) < 0) {
		return failure("no stream info: " + oqb::av_error(err));
	}
	const AVCodec *dec = nullptr;
	int stream = av_find_best_stream(s.fmt, AVMEDIA_TYPE_VIDEO, -1, -1, &dec, 0);
	if (stream < 0 || !dec) {
		return failure("no decodable picture stream");
	}
	AVStream *st = s.fmt->streams[stream];
	s.codec = avcodec_alloc_context3(dec);
	avcodec_parameters_to_context(s.codec, st->codecpar);
	if ((err = avcodec_open2(s.codec, dec, nullptr)) < 0) {
		return failure("can't open decoder: " + oqb::av_error(err));
	}

	// Frame timing: timestamps where the container has them (GIF, APNG,
	// AVI/MOV), otherwise the stream's frame rate, otherwise 10 fps.
	const double tb = av_q2d(st->time_base);
	double fallback_ms = DEFAULT_DELAY_MS;
	AVRational rate = st->avg_frame_rate.num ? st->avg_frame_rate : st->r_frame_rate;
	if (rate.num > 0 && rate.den > 0 && av_q2d(rate) < 240.0) {
		fallback_ms = 1000.0 / av_q2d(rate);
	}

	Array frames;
	PackedInt32Array delays;
	int width = 0;
	int height = 0;
	int64_t pixels = 0;
	int64_t last_pts = AV_NOPTS_VALUE;

	s.packet = av_packet_alloc();
	s.frame = av_frame_alloc();

	auto take = [&](AVFrame *f) -> bool {
		if (width == 0) {
			width = f->width;
			height = f->height;
		}
		if (f->width != width || f->height != height || width <= 0 || height <= 0) {
			return true; // skip frames of a different size
		}
		if (frames.size() >= max_frames || pixels + int64_t(width) * height > max_pixels) {
			return false;
		}
		s.sws = sws_getCachedContext(s.sws, width, height, static_cast<AVPixelFormat>(f->format),
				width, height, AV_PIX_FMT_RGBA, SWS_POINT, nullptr, nullptr, nullptr);
		if (!s.sws) {
			return false;
		}
		PackedByteArray rgba;
		rgba.resize(int64_t(width) * height * 4);
		uint8_t *dst[] = { rgba.ptrw() };
		int dst_stride[] = { width * 4 };
		sws_scale(s.sws, f->data, f->linesize, 0, height, dst, dst_stride);
		frames.push_back(rgba);
		pixels += int64_t(width) * height;

		int64_t pts = f->best_effort_timestamp;
		if (pts != AV_NOPTS_VALUE && last_pts != AV_NOPTS_VALUE && pts > last_pts && tb > 0.0) {
			delays[delays.size() - 1] = std::max(10, int(std::lround((pts - last_pts) * tb * 1000.0)));
		}
		int this_ms = int(std::lround(fallback_ms));
		if (f->duration > 0 && tb > 0.0) {
			this_ms = std::max(10, int(std::lround(f->duration * tb * 1000.0)));
		}
		delays.push_back(this_ms);
		last_pts = pts;
		return true;
	};

	bool more = true;
	while (more && av_read_frame(s.fmt, s.packet) >= 0) {
		if (s.packet->stream_index == stream && avcodec_send_packet(s.codec, s.packet) >= 0) {
			while (more && avcodec_receive_frame(s.codec, s.frame) == 0) {
				more = take(s.frame);
				av_frame_unref(s.frame);
			}
		}
		av_packet_unref(s.packet);
	}
	if (more) {
		avcodec_send_packet(s.codec, nullptr);
		while (more && avcodec_receive_frame(s.codec, s.frame) == 0) {
			more = take(s.frame);
			av_frame_unref(s.frame);
		}
	}
	if (frames.is_empty()) {
		return failure("decoded no frames");
	}

	Dictionary d;
	d["ok"] = true;
	d["error"] = "";
	d["width"] = width;
	d["height"] = height;
	d["frames"] = frames;
	d["delays_ms"] = delays;
	d["codec"] = String(dec->name);
	return d;
}
