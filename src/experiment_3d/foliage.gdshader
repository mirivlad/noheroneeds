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
uniform vec4 touch = vec4(0.0);
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
	if (touch.w != 0.0 && height < 1.8) {
		vec2 away = origin.xz - touch.xz + vec2(0.07, 0.03);
		float impulse = touch.w * exp(-dot(away, away) * 2.5);
		wind.xz += normalize(away) * impulse * 0.10 * up * up;
	}
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
	// Keep fruit distinct; calm the leaf palette instead of saturating each crown.
	float grey = dot(c, vec3(0.25, 0.6, 0.15));
	c = mix(c, vec3(grey), green * 0.30 + (height > 1.8 ? 0.15 : 0.0));
	if (height > 1.8 || !vertex_colors) {
		// Imported leaves, including pale ferns, share the restrained palette. Bark and
		// red fruit retain their identifying colours; fine leaf detail stays.
		float leaf = smoothstep(0.0, 0.12, c.g - c.b) * smoothstep(-0.05, 0.15, c.g - c.r);
		float value = clamp(grey * 1.4, 0.0, 1.0);
		vec3 forest = mix(vec3(0.12, 0.20, 0.08), vec3(0.32, 0.40, 0.16), value);
		c = mix(c, forest, leaf * 0.85);
	}
	c = mix(c, vec3(0.48, 0.42, 0.27), climate_tint.r * green * 0.65);
	c = mix(c, vec3(0.62, 0.65, 0.59), climate_tint.g * green * 0.45);
	ALPHA = a;  // leaf cards keep their cut-out shape
	ALPHA_SCISSOR_THRESHOLD = 0.2;  // as the models' own leaves
	float shade = mix(0.75, 1.08, smoothstep(0.05, 0.95, up));
	vec3 tint = mix(vec3(0.92, 0.96, 0.86), vec3(1.02, 1.0, 0.90), own);
	ALBEDO = c * tint * shade;
	ROUGHNESS = 0.92;
}
