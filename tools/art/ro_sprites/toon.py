"""Flat toon materials for the RO sprite pipeline (Blender side).

A material is a ramp of palette colours indexed by how much sun a surface gets
(Diffuse -> Shader to RGB -> constant ColorRamp) and sent out as emission, so
the render holds only the listed colours; the sprite post-process keeps them.
"""
import bpy


def linear(hex_colour):
	c = []
	for i in (1, 3, 5):
		s = int(hex_colour[i:i + 2], 16) / 255
		c.append(s / 12.92 if s <= 0.04045 else ((s + 0.055) / 1.055) ** 2.4)
	return (*c, 1.0)


def sock(sockets, name, kind):
	return next(s for s in sockets if s.name == name and s.type == kind)


def ramp(nodes, palette):
	r = nodes.new("ShaderNodeValToRGB")
	cr = r.color_ramp
	cr.interpolation = "CONSTANT"
	while len(cr.elements) < len(palette):
		cr.elements.new(0.5)
	for e, (pos, colour) in zip(cr.elements, palette):
		e.position = pos
		e.color = linear(colour)
	return r


def mix(nodes, links, factor, a, b):
	m = nodes.new("ShaderNodeMix")
	m.data_type = "RGBA"
	links.new(factor, sock(m.inputs, "Factor", "VALUE"))
	links.new(a, sock(m.inputs, "A", "RGBA"))
	links.new(b, sock(m.inputs, "B", "RGBA"))
	return sock(m.outputs, "Result", "RGBA")


def ramp_material(name, palette, under=None):
	"""under = (face attribute, palette) painted where the attribute is 1."""
	mat = bpy.data.materials.new(name)
	mat.use_nodes = True
	nodes, links = mat.node_tree.nodes, mat.node_tree.links
	nodes.clear()
	diffuse = nodes.new("ShaderNodeBsdfDiffuse")
	diffuse.inputs["Color"].default_value = (1, 1, 1, 1)
	light = nodes.new("ShaderNodeShaderToRGB")
	links.new(diffuse.outputs[0], light.inputs[0])
	base = ramp(nodes, palette)
	links.new(light.outputs["Color"], base.inputs["Fac"])
	colour = base.outputs["Color"]
	if under:
		attr = nodes.new("ShaderNodeAttribute")
		attr.attribute_name = under[0]
		other = ramp(nodes, under[1])
		links.new(light.outputs["Color"], other.inputs["Fac"])
		colour = mix(nodes, links, attr.outputs["Fac"], colour, other.outputs["Color"])
	emit = nodes.new("ShaderNodeEmission")
	links.new(colour, emit.inputs["Color"])
	out = nodes.new("ShaderNodeOutputMaterial")
	links.new(emit.outputs[0], out.inputs["Surface"])
	return mat
