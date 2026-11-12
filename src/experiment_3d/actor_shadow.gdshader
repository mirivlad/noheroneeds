shader_type spatial;
render_mode unshaded, cull_disabled, shadows_disabled, depth_draw_never;

void fragment() {
	float radius = length(UV * 2.0 - 1.0);
	ALBEDO = vec3(0.055, 0.045, 0.035);
	ALPHA = (1.0 - smoothstep(0.25, 1.0, radius)) * 0.25;
}
