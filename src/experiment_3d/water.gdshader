shader_type spatial;
render_mode cull_disabled;
// Opaque stylised water: no screen/depth reads, refraction or extra viewports.
// Ground picking and simulation keep the original, undisplaced triangles.
uniform sampler2D control_map : filter_nearest, repeat_disable;
uniform vec2 chunk_origin;
uniform float ripple_strength : hint_range(0.0, 1.0) = 0.5;
varying vec2 water_at;

float kind(vec2 cell) {
	return floor(texture(control_map, (cell - chunk_origin + vec2(1.5)) / 34.0).r * 255.0 + 0.5);
}

float depth_at(vec2 cell) {
	float id = kind(cell);
	return id == 13.0 ? 0.15 : (id == 14.0 ? 1.0 : (id == 12.0 ? 0.55 : 0.0));
}

void vertex() { water_at = VERTEX.xz; }

void fragment() {
	vec2 at = water_at - vec2(0.5);
	vec2 cell = floor(at);
	vec2 blend = smoothstep(vec2(0.05), vec2(0.95), fract(at));
	float depth = mix(mix(depth_at(cell), depth_at(cell + vec2(1, 0)), blend.x),
		mix(depth_at(cell + vec2(0, 1)), depth_at(cell + vec2(1, 1)), blend.x), blend.y);
	vec3 color = mix(vec3(0.16, 0.30, 0.29), vec3(0.065, 0.16, 0.21), depth);
	float a = dot(water_at, vec2(1.15, 0.72)) + TIME * 0.85;
	float b = dot(water_at, vec2(-0.55, 1.38)) - TIME * 0.62;
	float wave = sin(a) * 0.6 + sin(b) * 0.4;
	color *= 1.0 + wave * 0.07 * ripple_strength;
	float glint = smoothstep(0.85, 1.0, wave) * 0.035 * ripple_strength;
	ALBEDO = color + vec3(0.55, 0.65, 0.65) * glint;
	NORMAL = normalize(NORMAL + vec3(cos(a) * 0.05, 0.0, cos(b) * 0.05) * ripple_strength);
	ROUGHNESS = 0.38;
	SPECULAR = 0.28;
}
