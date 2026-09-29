// Floor/ceiling tiles drawn as one MultiMesh: every tile image of the level
// is a layer of `tiles`; INSTANCE_CUSTOM.r carries the layer index.
shader_type spatial;
render_mode unshaded, cull_disabled;

uniform sampler2DArray tiles : source_color, filter_nearest, repeat_disable;

varying flat float layer;

void vertex() {
	layer = INSTANCE_CUSTOM.r;
}

void fragment() {
	ALBEDO = texture(tiles, vec3(UV, layer)).rgb;
}
