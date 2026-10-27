"""Palette of the RO sprite pipeline, shared by the Blender and the Pillow side.

Toon ramps: (light level from which the colour applies, sRGB hex), darkest first.
"""

# Skin and hair are drawn in greys and painted the character's colour in the game (hair.py,
# ro_skin.gdshader, ro_hair.gdshader): the MIDDLE grey is the colour itself, darker greys
# darken it, lighter ones lift it towards white by up to LIFT (at white). Skin greys stay
# under white: the white highlight of the drawn eyes is not skin.
SKIN = [(0.0, "#686868"), (0.12, "#909090"), (0.45, "#dcdcdc")]
SKIN_MIDDLE, SKIN_LIFT = 0x90, 0.8
TRUNKS = [(0.0, "#1b1d33"), (0.12, "#2c3256"), (0.45, "#434c7d")]
HAIR = [(0.0, "#505050"), (0.12, "#808080"), (0.45, "#b0b0b0"), (0.85, "#e0e0e0")]
HAIR_MIDDLE, HAIR_LIFT = 0x80, 0.55

# Clothes and gear (stage 4)
def tones(dark, mid, light, shine=None):
	out = [(0.0, dark), (0.12, mid), (0.45, light)]
	return out + [(0.85, shine)] if shine else out


LINEN = tones("#8f8778", "#c8bfac", "#ece5d3")
WALNUT = tones("#3a281c", "#5b402e", "#7c5a41")
BOOT_LEATHER = tones("#24170f", "#3f2a1c", "#61422c")
BOOT_CUFF = tones("#4a3220", "#6e4c32", "#946a48")
TAN_LEATHER = tones("#4b3020", "#77502f", "#a17246")
DARK_LEATHER = tones("#25170e", "#3e2919", "#5a3d26")
IRON = tones("#3f444c", "#6c737e", "#a3abb6", "#dde2e8")
IRON_DARK = tones("#2b2f35", "#4b5058", "#717882")
FELT = tones("#33241b", "#523b2c", "#735641")
HAT_BAND = tones("#17110d", "#2a1f18", "#3e3026")
FUR_BROWN = tones("#43301f", "#6a4d33", "#8f6c4b")
FUR_LIGHT = tones("#776753", "#a69378", "#cfbfa2")
WOOL_GREY = tones("#45474e", "#696c74", "#8f929a")
WOOD = tones("#40291a", "#66442b", "#8c6340")
FLINT = tones("#2e2c31", "#4b4850", "#6f6b76", "#9a97a1")
STONE = tones("#4b4943", "#6f6c64", "#97938a")
CORD = tones("#5a4a2e", "#83704a", "#a8956a")
BOW_STRING = tones("#8a8370", "#bcb59e", "#e0dac6")

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
