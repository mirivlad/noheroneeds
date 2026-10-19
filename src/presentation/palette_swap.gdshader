shader_type canvas_item;
// Recolours an LPC layer: each pixel of a source palette ramp becomes the
// same step of the chosen ramp (skin, hair, eyes, cloth). Others stay.

uniform int count = 0;
uniform vec4 from_colors[32] : source_color;
uniform vec4 to_colors[32] : source_color;
// The sprite's modulate alone (COLOR in fragment() already holds the texel).
varying vec4 tint;

void vertex() {
	tint = COLOR;
}

void fragment() {
	vec4 c = texture(TEXTURE, UV);
	for (int i = 0; i < count; i++) {
		if (distance(c.rgb, from_colors[i].rgb) < 0.004) {
			c.rgb = to_colors[i].rgb;
			break;
		}
	}
	COLOR = c * tint;
}
