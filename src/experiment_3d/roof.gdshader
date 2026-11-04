shader_type spatial;
render_mode cull_disabled;
uniform int roof_kind = 0;
void fragment() {
	vec2 p = UV * vec2(5.0, 4.0);
	float row = floor(p.y);
	p.x += mod(row, 2.0) * 0.5;
	vec2 tile = fract(p);
	float variation = fract(sin(dot(floor(p), vec2(12.9898, 78.233))) * 43758.5453);
	float grout = smoothstep(0.01, 0.06, tile.x) * smoothstep(0.01, 0.08, tile.y);
	ALBEDO = mix(vec3(0.27,0.16,0.12), vec3(0.57,0.30,0.20) * (0.89 + variation * 0.16 + tile.y * 0.1), grout);
	if (roof_kind == 1) {
		float straw = fract(sin(floor(UV.x * 35.0) * 7.13 + floor(UV.y * 5.0)) * 136.71);
		ALBEDO = vec3(0.57, 0.43, 0.22) * (0.82 + straw * 0.28);
	} else if (roof_kind == 2) {
		ALBEDO = mix(vec3(0.18, 0.13, 0.08), vec3(0.40, 0.30, 0.18) * (0.85 + variation * 0.25), grout);
	} else if (roof_kind == 3) {
		ALBEDO = mix(vec3(0.16, 0.19, 0.21), vec3(0.35, 0.39, 0.42) * (0.9 + variation * 0.2), grout);
	} else if (roof_kind == 4) {
		ALBEDO = vec3(0.71, 0.65, 0.49) * (0.95 + variation * 0.08);
	}
	ROUGHNESS = 0.95;
}
