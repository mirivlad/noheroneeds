shader_type canvas_item;
// An RO hairstyle (tools/art/ro_sprites/hair.py): its atlas holds the grey tone
// in red and the pixel's depth byte in green. The grey becomes a tone of
// hair_colour: the middle grey is the colour itself, darker greys darken it,
// lighter ones lift it towards white. Under headwear a pixel inside the
// headwear's keep-out (its near side's depth byte in red, its far side's in
// green) is not drawn.

uniform vec3 hair_colour = vec3(0.49, 0.27, 0.075);
uniform bool cut = false;
uniform sampler2D keep_out : filter_nearest;
// Keep-out texel = hair texel + offset, inside keep_rect (x, y, w, h) only.
uniform vec2 offset;
uniform vec4 keep_rect;
const float MIDDLE = 128.0 / 255.0;
const float LIFT = 0.55;
// The sprite's modulate alone (COLOR in fragment() already holds the texel).
varying vec4 tint;

void vertex() {
	tint = COLOR;
}

void fragment() {
	vec4 c = texture(TEXTURE, UV);
	if (cut && c.a > 0.0) {
		vec2 p = floor(UV * vec2(textureSize(TEXTURE, 0))) + offset;
		if (all(greaterThanEqual(p, keep_rect.xy)) && all(lessThan(p, keep_rect.xy + keep_rect.zw))) {
			vec4 k = texelFetch(keep_out, ivec2(p), 0);
			float d = round(c.g * 255.0);
			float near = round(k.r * 255.0);
			float far = round(k.g * 255.0);
			if (k.a > 0.5 && d > 0.0 && d <= near + 1.0 && d >= far - 1.0) {
				discard;
			}
		}
	}
	float t = c.r;
	vec3 tone = t <= MIDDLE ? hair_colour * t / MIDDLE
		: hair_colour + (vec3(1.0) - hair_colour) * (t - MIDDLE) / (1.0 - MIDDLE) * LIFT;
	COLOR = vec4(clamp(tone, 0.0, 1.0), c.a) * tint;
}
