// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (c) 2026 Mark Toman and OpenQBORG contributors
// Floor/ceiling tiles drawn as one MultiMesh: every tile image of the level
// is a layer of `tiles`; INSTANCE_CUSTOM.r carries the layer index.
shader_type spatial;
render_mode unshaded, cull_disabled;

uniform sampler2DArray tiles : source_color, filter_nearest, repeat_disable;
// Animated tile images store every frame's tiles one after another;
// BorgWorld advances this by the tile count each frame.
uniform float frame_offset = 0.0;

varying flat float layer;

void vertex() {
	layer = INSTANCE_CUSTOM.r + frame_offset;
}

void fragment() {
	ALBEDO = texture(tiles, vec3(UV, layer)).rgb;
}
