shader_type spatial;
render_mode cull_disabled;
uniform sampler2D atlas : source_color, filter_linear_mipmap, repeat_disable;
uniform sampler2D control_map : filter_nearest, repeat_disable;
uniform vec2 chunk_origin;
varying vec2 world_uv;
void vertex() { world_uv = VERTEX.xz; }
vec3 ground(vec2 cell, vec2 at) {
	float id = floor(texture(control_map, (cell - chunk_origin + vec2(1.5)) / 34.0).r * 255.0 + 0.5);
	vec2 tile = vec2(mod(id, 4.0), floor(id / 4.0));
	vec2 fill = fract(at * 0.5);
	vec3 color = textureGrad(atlas, (tile * 64.0 + vec2(1.0) + fill * 62.0) / 256.0, dFdx(at) * (31.0 / 256.0), dFdy(at) * (31.0 / 256.0)).rgb;
	if (id == 6.0) color = mix(color, vec3(dot(color, vec3(0.33))), 0.85) * 1.25;
	if (id == 9.0) {
		float grain = smoothstep(0.18, 0.8, dot(color, vec3(0.33)));
		float patch = 0.5 + 0.5 * sin(at.x * 0.17 + sin(at.y * 0.13)) * sin(at.y * 0.11 + at.x * 0.07);
		vec3 rubble = mix(vec3(0.15, 0.16, 0.14), vec3(0.28, 0.28, 0.24), grain);
		color = mix(rubble, vec3(0.23, 0.20, 0.16), patch * 0.38);
	}
	// Render palette only; LPC source fills and the authoritative ground IDs stay intact.
	float value = clamp(dot(color, vec3(0.25, 0.6, 0.15)) * 1.6, 0.0, 1.0);
	if (id == 0.0) color = mix(vec3(0.16, 0.23, 0.10), vec3(0.27, 0.34, 0.18), value);
	if (id == 1.0) color = mix(vec3(0.23, 0.18, 0.12), vec3(0.34, 0.275, 0.19), value);
	if (id == 2.0) color = mix(vec3(0.12, 0.16, 0.09), vec3(0.22, 0.25, 0.14), value);
	if (id == 3.0) color = mix(vec3(0.36, 0.32, 0.23), vec3(0.49, 0.44, 0.32), value);
	if (id == 4.0) color = mix(vec3(0.38, 0.43, 0.44), vec3(0.56, 0.60, 0.60), value);
	if (id == 7.0) color = mix(vec3(0.28, 0.26, 0.13), vec3(0.39, 0.36, 0.21), value);
	if (id == 8.0 || id == 10.0) color = mix(vec3(0.14, 0.12, 0.085), vec3(0.25, 0.21, 0.15), value);
	if (id == 11.0) color = mix(vec3(0.12, 0.20, 0.12), vec3(0.23, 0.30, 0.19), value);
	if (id >= 12.0 && id <= 14.0) color = mix(vec3(0.16, 0.30, 0.29), vec3(0.065, 0.16, 0.21), id == 13.0 ? 0.15 : (id == 14.0 ? 1.0 : 0.55));
	// Preserve the water-coloured substrate visible between bridge boards.
	if (id == 15.0) color = vec3(0.10, 0.20, 0.22);
	// Slow tonal variation crosses cell and chunk edges without new surface noise.
	if (id < 12.0 && id != 5.0 && id != 6.0) color *= 0.98 + 0.025 * sin(at.x * 0.09 + sin(at.y * 0.07));
	return color;
}
void fragment() {
	vec2 at = world_uv - vec2(0.5);
	vec2 cell = floor(at);
	vec2 blend = smoothstep(vec2(0.18), vec2(0.82), fract(at) + vec2(sin(world_uv.y * 1.7), sin(world_uv.x * 1.3)) * 0.035);
	vec3 a = mix(ground(cell, world_uv), ground(cell + vec2(1,0), world_uv), blend.x);
	vec3 b = mix(ground(cell + vec2(0,1), world_uv), ground(cell + vec2(1,1), world_uv), blend.x);
	ALBEDO = mix(a, b, blend.y) * 0.86;
	ROUGHNESS = 1.0;
}
