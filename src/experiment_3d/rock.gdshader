shader_type spatial;
render_mode cull_disabled;
uniform sampler2D rock_texture : source_color, filter_linear_mipmap, repeat_enable;
varying vec3 rock_at;
varying vec3 rock_normal;
varying float surface_kind;

float grain_hash(vec3 p) {
	return fract(sin(dot(p, vec3(12.9898, 78.233, 37.719))) * 43758.5453);
}

void vertex() {
	rock_at = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	rock_normal = MODEL_NORMAL_MATRIX * NORMAL;
	surface_kind = COLOR.r * 3.0;
}

void fragment() {
	vec3 normal = normalize(rock_normal);
	vec3 weights = pow(abs(normal), vec3(4.0));
	weights /= max(dot(weights, vec3(1.0)), 0.001);
	float texture_grain = dot(texture(rock_texture, rock_at.zy * 0.65).rgb, vec3(0.333)) * weights.x
		+ dot(texture(rock_texture, rock_at.xz * 0.65).rgb, vec3(0.333)) * weights.y
		+ dot(texture(rock_texture, rock_at.xy * 0.65).rgb, vec3(0.333)) * weights.z;
	float warp = sin(rock_at.x * 0.37) * 0.45 + sin(rock_at.z * 0.29) * 0.3;
	vec3 color;
	if (surface_kind < 0.5) {
		// Sedimentary beds bend slowly through the whole mass, across tiles.
		float layer = sin(rock_at.y * 4.4 + warp);
		color = mix(vec3(0.19, 0.175, 0.15), vec3(0.28, 0.26, 0.215), smoothstep(-0.7, 0.8, layer));
		color *= mix(0.82, 1.0, smoothstep(0.03, 0.14, abs(layer - 0.72)));
	} else if (surface_kind < 1.5) {
		// Intersecting geological joints, independent of the cell grid.
		float a = abs(sin(dot(rock_at, vec3(1.8, 0.43, 1.25)) + warp));
		float b = abs(sin(dot(rock_at, vec3(-0.7, 0.9, 1.3))));
		float joint = smoothstep(0.035, 0.11, min(a, b));
		color = vec3(0.19, 0.215, 0.23) * mix(0.70, 1.07, joint);
	} else if (surface_kind < 2.5) {
		// Granite flecks stay subtle; silhouette and facets carry the form.
		float speck = grain_hash(floor(rock_at * 10.0));
		color = vec3(0.245, 0.24, 0.225) * mix(0.88, 1.09, speck);
	} else {
		float worn = sin(rock_at.x * 0.83 + sin(rock_at.z * 0.67) + rock_at.y * 0.31);
		color = mix(vec3(0.185, 0.18, 0.16), vec3(0.27, 0.245, 0.195), worn * 0.5 + 0.5);
	}
	color *= 0.95 + 0.08 * texture_grain;
	// Dust/soil rests on upward-facing ledges, rather than painting walls green.
	float soil = smoothstep(0.65, 0.98, normal.y) * (0.07 + 0.06 * sin(rock_at.x * 0.7 + rock_at.z * 0.9));
	ALBEDO = mix(color, vec3(0.235, 0.205, 0.15), soil);
	ROUGHNESS = 0.97;
}
