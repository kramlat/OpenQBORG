// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (c) 2026 Mark Toman and OpenQBORG contributors
#include "ffmpeg_audio_decoder.h"
#include "memory_io.h"

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

using oqb::av_error;
constexpr int MAX_MIX_RATE = 192000;

// Owns every FFmpeg object for one decode, so early returns can't leak.
struct Session {
	oqb::MemoryReader reader;
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

	int err = oqb::open_input(&s.reader, &s.fmt, &s.io);
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
