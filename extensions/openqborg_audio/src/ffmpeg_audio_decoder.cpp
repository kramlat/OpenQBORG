// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (c) 2026 Mark Toman and OpenQBORG contributors
#include "ffmpeg_audio_decoder.h"

#include <godot_cpp/core/class_db.hpp>

#include <algorithm>
#include <cstring>
#include <vector>

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/channel_layout.h>
#include <libavutil/opt.h>
#include <libswresample/swresample.h>
}

using namespace godot;

namespace {

constexpr int IO_BUFFER_SIZE = 32 * 1024;
constexpr int MAX_MIX_RATE = 192000;

struct MemoryReader {
	const uint8_t *data = nullptr;
	int64_t size = 0;
	int64_t pos = 0;
};

int read_packet(void *opaque, uint8_t *buf, int buf_size) {
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

int64_t seek(void *opaque, int64_t offset, int whence) {
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

String av_error(int err) {
	char buf[AV_ERROR_MAX_STRING_SIZE] = {};
	av_strerror(err, buf, sizeof(buf));
	return String(buf);
}

// Owns every FFmpeg object for one decode, so early returns can't leak.
struct Session {
	MemoryReader reader;
	AVIOContext *io = nullptr;
	AVFormatContext *fmt = nullptr;
	AVCodecContext *codec = nullptr;
	SwrContext *swr = nullptr;
	AVPacket *packet = nullptr;
	AVFrame *frame = nullptr;

	~Session() {
		av_frame_free(&frame);
		av_packet_free(&packet);
		swr_free(&swr);
		avcodec_free_context(&codec);
		avformat_close_input(&fmt);
		if (io) {
			av_freep(&io->buffer);
			avio_context_free(&io);
		}
	}
};

Dictionary failure(const String &why) {
	Dictionary d;
	d["ok"] = false;
	d["error"] = why;
	return d;
}

} // namespace

void FFmpegAudioDecoder::_bind_methods() {
	ClassDB::bind_static_method("FFmpegAudioDecoder", D_METHOD("decode", "bytes", "max_seconds"),
			&FFmpegAudioDecoder::decode, DEFVAL(0.0));
	ClassDB::bind_static_method("FFmpegAudioDecoder", D_METHOD("ffmpeg_version"),
			&FFmpegAudioDecoder::ffmpeg_version);
}

String FFmpegAudioDecoder::ffmpeg_version() {
	return String(av_version_info());
}

Dictionary FFmpegAudioDecoder::decode(const PackedByteArray &bytes, double max_seconds) {
	if (bytes.is_empty()) {
		return failure("empty input");
	}
	Session s;
	s.reader.data = bytes.ptr();
	s.reader.size = bytes.size();

	auto *io_buffer = static_cast<uint8_t *>(av_malloc(IO_BUFFER_SIZE));
	s.io = avio_alloc_context(io_buffer, IO_BUFFER_SIZE, 0, &s.reader, read_packet, nullptr, seek);
	if (!s.io) {
		av_free(io_buffer);
		return failure("out of memory");
	}
	s.fmt = avformat_alloc_context();
	s.fmt->pb = s.io;
	s.fmt->flags |= AVFMT_FLAG_CUSTOM_IO;
	int err = avformat_open_input(&s.fmt, nullptr, nullptr, nullptr);
	if (err < 0) {
		return failure("unrecognised audio: " + av_error(err));
	}
	if ((err = avformat_find_stream_info(s.fmt, nullptr)) < 0) {
		return failure("no stream info: " + av_error(err));
	}
	const AVCodec *dec = nullptr;
	int stream = av_find_best_stream(s.fmt, AVMEDIA_TYPE_AUDIO, -1, -1, &dec, 0);
	if (stream < 0 || !dec) {
		return failure("no decodable audio stream");
	}
	s.codec = avcodec_alloc_context3(dec);
	avcodec_parameters_to_context(s.codec, s.fmt->streams[stream]->codecpar);
	if ((err = avcodec_open2(s.codec, dec, nullptr)) < 0) {
		return failure("can't open decoder: " + av_error(err));
	}

	const int rate = std::clamp(s.codec->sample_rate, 1, MAX_MIX_RATE);
	const bool stereo = s.codec->ch_layout.nb_channels >= 2;
	AVChannelLayout out_layout;
	av_channel_layout_default(&out_layout, stereo ? 2 : 1);
	err = swr_alloc_set_opts2(&s.swr, &out_layout, AV_SAMPLE_FMT_S16, rate,
			&s.codec->ch_layout, s.codec->sample_fmt, s.codec->sample_rate, 0, nullptr);
	if (err < 0 || swr_init(s.swr) < 0) {
		return failure("can't set up resampler");
	}

	const int out_channels = stereo ? 2 : 1;
	const int64_t max_frames = max_seconds > 0.0 ? static_cast<int64_t>(max_seconds * rate) : INT64_MAX;
	std::vector<int16_t> pcm;
	std::vector<int16_t> chunk;
	int64_t frames_out = 0;

	s.packet = av_packet_alloc();
	s.frame = av_frame_alloc();

	auto convert = [&](const AVFrame *f) {
		int in_samples = f ? f->nb_samples : 0;
		int cap = swr_get_out_samples(s.swr, in_samples);
		if (cap <= 0) {
			return;
		}
		chunk.resize(static_cast<size_t>(cap) * out_channels);
		uint8_t *out[] = { reinterpret_cast<uint8_t *>(chunk.data()) };
		int got = swr_convert(s.swr, out, cap,
				f ? const_cast<const uint8_t **>(f->extended_data) : nullptr, in_samples);
		if (got > 0) {
			int64_t keep = std::min<int64_t>(got, max_frames - frames_out);
			pcm.insert(pcm.end(), chunk.begin(), chunk.begin() + keep * out_channels);
			frames_out += keep;
		}
	};

	auto drain = [&]() {
		while (avcodec_receive_frame(s.codec, s.frame) == 0) {
			convert(s.frame);
			av_frame_unref(s.frame);
		}
	};

	while (frames_out < max_frames && av_read_frame(s.fmt, s.packet) >= 0) {
		if (s.packet->stream_index == stream && avcodec_send_packet(s.codec, s.packet) >= 0) {
			drain();
		}
		av_packet_unref(s.packet);
	}
	avcodec_send_packet(s.codec, nullptr); // flush the decoder...
	drain();
	if (frames_out < max_frames) {
		convert(nullptr); // ...and the resampler
	}

	if (pcm.empty()) {
		return failure("decoded no audio");
	}
	PackedByteArray data;
	data.resize(static_cast<int64_t>(pcm.size() * sizeof(int16_t)));
	std::memcpy(data.ptrw(), pcm.data(), pcm.size() * sizeof(int16_t));

	Dictionary d;
	d["ok"] = true;
	d["error"] = "";
	d["mix_rate"] = rate;
	d["stereo"] = stereo;
	d["data"] = data;
	d["codec"] = String(dec->name);
	return d;
}
