"""Palette of the RO sprite pipeline, shared by the Blender and the Pillow side.

Toon ramps: (light level from which the colour applies, sRGB hex), darkest first.
"""

SKIN = [(0.0, "#b06c55"), (0.12, "#dc9b7e"), (0.45, "#f6cfb2")]
TRUNKS = [(0.0, "#1b1d33"), (0.12, "#2c3256"), (0.45, "#434c7d")]
HAIR_SILVER = [(0.0, "#625e6e"), (0.12, "#938ea0"), (0.45, "#c6c2ce"), (0.85, "#e9e7ee")]

# Drawn face
EYE_LINE = "#24140f"
IRIS_DARK = "#4a2a1e"
IRIS_LIGHT = "#8c5c3c"
HIGHLIGHT = "#ffffff"
SCLERA = "#f6f1ea"
BROW = "#4a2a1e"
MOUTH = "#8a3f33"


def rgb(hex_colour):
	return tuple(int(hex_colour[i:i + 2], 16) for i in (1, 3, 5))
