shader_type spatial;
render_mode unshaded, cull_disabled, shadows_disabled;
// ViewportTexture already contains the composed sRGB paper doll. Explicit
// conversion avoids Compatibility's approximate conversion crushing dark ink.
uniform sampler2D paper : filter_nearest, repeat_disable;
// Metres the whole picture is lifted toward the eye, for ground that is not
// quite flat under the feet.
const float LIFT = 0.2;
void vertex() {
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(
		INV_VIEW_MATRIX[0] * length(MODEL_MATRIX[0].xyz),
		INV_VIEW_MATRIX[1] * length(MODEL_MATRIX[1].xyz),
		INV_VIEW_MATRIX[2] * length(MODEL_MATRIX[2].xyz), MODEL_MATRIX[3]);
}
void fragment() {
	vec4 color = texture(paper, UV);
	if (color.a < 0.5) discard;
	// The card faces the eye, so all of it would lie at the depth of the feet:
	// what is drawn below them (the toes, a tool on the ground) went under the
	// ground and a bank behind hid the head. Each point takes the depth it has
	// in the world instead: above the feet standing upright, below them lying
	// on the ground toward the eye.
	float up = max(INV_VIEW_MATRIX[1].y, 0.05);  // how much of a height the screen shows
	float toward = max(INV_VIEW_MATRIX[2].y, 0.05);  // how much of it comes toward the eye
	float above = VERTEX.y - (VIEW_MATRIX * vec4(NODE_POSITION_WORLD, 1.0)).y;
	vec3 at = VERTEX;
	at.z += LIFT + (above > 0.0 ? above * toward / up : -above * up / toward);
	vec4 clip = PROJECTION_MATRIX * vec4(at, 1.0);
#if CURRENT_RENDERER == RENDERER_COMPATIBILITY
	DEPTH = clip.z / clip.w * 0.5 + 0.5;
#else
	DEPTH = clip.z / clip.w;
#endif
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
