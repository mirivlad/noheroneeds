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
varying float up;
varying float own;

float hash(vec3 p) {
	return fract(sin(dot(p, vec3(12.9898, 78.233, 37.719))) * 43758.5453);
}

void vertex() {
	up = clamp(VERTEX.y / max(height, 0.01), 0.0, 1.0);
	own = hash(vec3(float(INSTANCE_ID), 1.7, 3.1));
}

void fragment() {
	vec3 c = albedo.rgb;
	float a = albedo.a;
	if (has_tex) {
		vec4 t = texture(albedo_tex, UV);
		c *= t.rgb;
		a *= t.a;
	}
	ALPHA = a;  // leaf cards keep their cut-out shape
	ALPHA_SCISSOR_THRESHOLD = 0.2;  // as the models' own leaves
	float shade = mix(0.75, 1.08, smoothstep(0.05, 0.95, up));
	vec3 tint = mix(vec3(0.9, 1.0, 0.86), vec3(1.1, 1.03, 0.86), own);
	ALBEDO = c * tint * shade;
	ROUGHNESS = 0.92;
}
