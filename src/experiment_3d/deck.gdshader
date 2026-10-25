shader_type spatial;
void fragment() {
	vec2 p = UV * vec2(5.0, 1.0);
	float seam = smoothstep(0.0, 0.035, fract(p.x));
	float grain = sin(UV.y * 105.0 + sin(UV.x * 90.0) * 0.4) * 0.025;
	float plank = fract(sin(floor(p.x) * 12.3) * 537.8) * 0.08;
	ALBEDO = mix(vec3(0.23,0.17,0.11), vec3(0.55,0.40,0.23) + grain + plank, seam);
	ROUGHNESS = 0.95;
}
