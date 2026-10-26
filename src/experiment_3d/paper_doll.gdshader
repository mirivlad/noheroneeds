shader_type spatial;
render_mode unshaded, cull_disabled, shadows_disabled;
// ViewportTexture already contains the composed sRGB paper doll. Explicit
// conversion avoids Compatibility's approximate conversion crushing dark ink.
uniform sampler2D paper : filter_nearest, repeat_disable;
void vertex() {
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(
		INV_VIEW_MATRIX[0] * length(MODEL_MATRIX[0].xyz),
		INV_VIEW_MATRIX[1] * length(MODEL_MATRIX[1].xyz),
		INV_VIEW_MATRIX[2] * length(MODEL_MATRIX[2].xyz), MODEL_MATRIX[3]);
}
void fragment() {
	vec4 color = texture(paper, UV);
	if (color.a < 0.5) discard;
	vec3 linear = mix(pow((color.rgb + vec3(0.055)) / 1.055, vec3(2.4)), color.rgb / 12.92, lessThanEqual(color.rgb, vec3(0.04045)));
	if (OUTPUT_IS_SRGB) {
		// Compatibility applies a cubic approximation internally. Invert
		// that approximation so dark outline colours survive the round trip.
		vec3 corrected = color.rgb;
		for (int i = 0; i < 5; i++) {
			vec3 value = corrected * (corrected * (corrected * 0.305306011 + 0.682171111) + 0.012522878);
			vec3 derivative = corrected * (corrected * 0.915918033 + 1.364342222) + 0.012522878;
			corrected = clamp(corrected - (value - linear) / derivative, vec3(0.0), vec3(1.0));
		}
		ALBEDO = corrected;
	} else {
		ALBEDO = linear;
	}
}
