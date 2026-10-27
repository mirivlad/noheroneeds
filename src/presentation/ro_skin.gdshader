shader_type canvas_item;
// An RO body (tools/art/ro_sprites/hair.py paint_skin): its skin is drawn in
// greys under white, each painted a tone of skin_colour as hair is
// (ro_hair.gdshader); the underwear and the drawn face keep their colours.

uniform vec3 skin_colour = vec3(0.863, 0.608, 0.494);
const float MIDDLE = 144.0 / 255.0;
const float LIFT = 0.8;
// The sprite's modulate alone (COLOR in fragment() already holds the texel).
varying vec4 tint;

void vertex() {
	tint = COLOR;
}

void fragment() {
	vec4 c = texture(TEXTURE, UV);
	ivec3 v = ivec3(round(c.rgb * 255.0));
	if (v.r == v.g && v.g == v.b && v.r < 240) {
		float t = c.r;
		vec3 tone = t <= MIDDLE ? skin_colour * t / MIDDLE
			: skin_colour + (vec3(1.0) - skin_colour) * (t - MIDDLE) / (1.0 - MIDDLE) * LIFT;
		c.rgb = clamp(tone, 0.0, 1.0);
	}
	COLOR = c * tint;
}
