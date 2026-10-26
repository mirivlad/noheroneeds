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
	if (id == 6.0 || id == 9.0) color = mix(color, vec3(dot(color, vec3(0.33))), 0.85) * 1.25;
	if (id == 7.0) color *= vec3(1.12, 0.91, 0.65);
	if (id == 8.0 || id == 10.0) color *= vec3(0.75, 0.68, 0.58);
	if (id >= 12.0) color = mix(vec3(0.16, 0.36, 0.44), vec3(0.28, 0.51, 0.56), color.r) * (id == 14.0 ? 0.75 : 1.0);
	return color;
}
void fragment() {
	vec2 at = world_uv - vec2(0.5);
	vec2 cell = floor(at);
	vec2 blend = smoothstep(vec2(0.18), vec2(0.82), fract(at));
	vec3 a = mix(ground(cell, world_uv), ground(cell + vec2(1,0), world_uv), blend.x);
	vec3 b = mix(ground(cell + vec2(0,1), world_uv), ground(cell + vec2(1,1), world_uv), blend.x);
	ALBEDO = mix(a, b, blend.y) * 0.86;
	ROUGHNESS = 1.0;
}
