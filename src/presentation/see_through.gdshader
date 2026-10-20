shader_type canvas_item;
// What stands in front of the player is seen through only round them (a
// window the size of a body), not as a whole: a wall or a crown keeps its
// look beyond the window. COLOR in fragment() is already texel * modulate.

uniform vec2 hole;           // the player's middle, world pixels
uniform float radius = 13.0; // world pixels
uniform float faded = 0.35;
varying vec2 world;

void vertex() {
	world = (MODEL_MATRIX * vec4(VERTEX, 0.0, 1.0)).xy;
}

void fragment() {
	float d = distance(world, hole);
	COLOR.a *= mix(faded, 1.0, smoothstep(radius - 3.0, radius, d));
}
