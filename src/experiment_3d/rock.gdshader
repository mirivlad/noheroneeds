shader_type spatial;
render_mode cull_disabled;  // a face turned inside out never leaves a hole one sees through
uniform sampler2D rock_texture : source_color, filter_linear_mipmap, repeat_enable;
varying vec3 rock_at;
varying vec3 rock_normal;
void vertex() {
	rock_at = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	rock_normal = MODEL_NORMAL_MATRIX * NORMAL;
}
void fragment() {
	vec3 weights = pow(abs(normalize(rock_normal)), vec3(4.0));
	weights /= max(dot(weights, vec3(1.0)), 0.001);
	vec3 x = texture(rock_texture, rock_at.zy * 0.65).rgb;
	vec3 y = texture(rock_texture, rock_at.xz * 0.65).rgb;
	vec3 z = texture(rock_texture, rock_at.xy * 0.65).rgb;
	vec3 color = x * weights.x + y * weights.y + z * weights.z;
	float grain = dot(color, vec3(0.333));
	float facet = 0.78 + 0.22 * max(dot(normalize(rock_normal), normalize(vec3(0.3,0.8,0.4))), 0.0);
	ALBEDO = mix(vec3(0.32,0.34,0.34), vec3(0.63,0.64,0.61), grain) * facet;
	ROUGHNESS = 1.0;
}
