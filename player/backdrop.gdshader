// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (c) 2026 Mark Toman and OpenQBORG contributors
// QBORG backdrop (<bdp>): a panorama strip behind the world that scrolls one
// image width per 90 degrees of turning, pinned to the horizon. Rows above and
// below the image repeat its top and bottom edge colours.
shader_type canvas_item;

uniform sampler2D sky : filter_nearest, repeat_disable;
uniform vec2 sky_size = vec2(256.0, 128.0);
uniform vec2 view_size = vec2(512.0, 512.0);
uniform float yaw = 0.0;
// Pixels (at the original 512-pixel-tall view) the image bottom sits below
// the screen centre: the level's POS value plus the current look pitch.
uniform float horizon_offset = 0.0;

void fragment() {
	float s = view_size.y / 512.0;
	vec2 px = UV * view_size;
	vec2 size = sky_size * s;
	float u = fract((px.x - (view_size.x - size.x) * 0.5) / size.x - yaw / (PI * 0.5) + 0.5);
	float bottom = view_size.y * 0.5 + horizon_offset * s;
	float v = clamp((px.y - (bottom - size.y)) / size.y, 0.5 / sky_size.y, 1.0 - 0.5 / sky_size.y);
	COLOR = texture(sky, vec2(u, v));
}
