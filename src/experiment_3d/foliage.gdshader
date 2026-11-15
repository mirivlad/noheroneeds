shader_type spatial;
render_mode cull_disabled;
// Plants (the author, 28.10.2026: trees were one flat colour each): the
// model's own colour, darker low in the crown and lighter at its top, and
// every plant a shade of its own. Leaf pictures need their mipmaps (without
// them a far crown is a noise of pixels, like an indexed picture).
uniform vec4 albedo : source_color = vec4(1.0);
uniform sampler2D albedo_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform bool has_tex = false;
uniform float height = 2.0;
uniform bool vertex_colors = false;
uniform float wind_strength : hint_range(0.0, 1.0) = 0.5;
varying float up;
varying float own;
varying vec2 climate_tint;

float hash(vec3 p) {
	return fract(sin(dot(p, vec3(12.9898, 78.233, 37.719))) * 43758.5453);
}

void vertex() {
	up = clamp(VERTEX.y / max(height, 0.01), 0.0, 1.0);
	// World position, rather than the batching order, survives chunk reloads.
	vec3 origin = MODEL_MATRIX[3].xyz;
	own = hash(origin);
	climate_tint = INSTANCE_CUSTOM.rg;
	float phase = dot(origin.xz, vec2(0.19, 0.13));
	float sway = sin(TIME * 1.3 + phase) + 0.35 * sin(TIME * 2.1 + phase * 1.7);
	vec3 wind = vec3(0.8, 0.0, 0.35) * sway * wind_strength * min(height * 0.12, 0.08) * up * up;
	// Project a world-space breeze into each rotated instance's local axes.
	VERTEX += vec3(dot(wind, normalize(MODEL_MATRIX[0].xyz)), 0.0, dot(wind, normalize(MODEL_MATRIX[2].xyz)));
}

void fragment() {
	vec3 c = albedo.rgb;
	if (vertex_colors) c *= COLOR.rgb;
	float a = albedo.a;
	if (has_tex) {
		vec4 t = texture(albedo_tex, UV);
		c *= t.rgb;
		a *= t.a;
	}
	// Seasonal drying affects green leaves, including textured tree crowns;
	// fruit, wood and seed heads keep their identifying colours.
	float green = smoothstep(0.0, 0.08, c.g - max(c.r, c.b));
	c = mix(c, vec3(0.48, 0.42, 0.27), climate_tint.r * green * 0.65);
	c = mix(c, vec3(0.62, 0.65, 0.59), climate_tint.g * green * 0.45);
	ALPHA = a;  // leaf cards keep their cut-out shape
	ALPHA_SCISSOR_THRESHOLD = 0.2;  // as the models' own leaves
	float shade = mix(0.75, 1.08, smoothstep(0.05, 0.95, up));
	vec3 tint = mix(vec3(0.9, 1.0, 0.86), vec3(1.1, 1.03, 0.86), own);
	ALBEDO = c * tint * shade;
	ROUGHNESS = 0.92;
}
