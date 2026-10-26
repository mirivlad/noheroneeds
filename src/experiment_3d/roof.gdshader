shader_type spatial;
render_mode cull_disabled;
void fragment() {
	vec2 p = UV * vec2(5.0, 4.0);
	float row = floor(p.y);
	p.x += mod(row, 2.0) * 0.5;
	vec2 tile = fract(p);
	float variation = fract(sin(dot(floor(p), vec2(12.9898, 78.233))) * 43758.5453);
	float grout = smoothstep(0.01, 0.06, tile.x) * smoothstep(0.01, 0.08, tile.y);
	ALBEDO = mix(vec3(0.27,0.16,0.12), vec3(0.57,0.30,0.20) * (0.89 + variation * 0.16 + tile.y * 0.1), grout);
	ROUGHNESS = 0.95;
}
