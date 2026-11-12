"""Own horse model and contact-aware quadruped poses (Blender side).

+Y forward, +Z up, metres. The source is this script, not the generated blend.
Shared RO toon materials and pixel reduction keep the character art's style.
"""
import math

import bpy
import bmesh
from mathutils import Matrix, Vector


def mesh(name, vertices, faces, material, arm, weights):
    data = bpy.data.meshes.new(name)
    data.from_pydata(vertices, [], faces)
    data.materials.append(material)
    data.update()
    obj = bpy.data.objects.new(name, data)
    bpy.context.scene.collection.objects.link(obj)
    obj.parent = arm
    for polygon in data.polygons:
        polygon.use_smooth = True
    groups = {}
    for i, point in enumerate(vertices):
        for bone, weight in weights(Vector(point)).items():
            if weight <= 0:
                continue
            if bone not in groups:
                groups[bone] = obj.vertex_groups.new(name=bone)
            groups[bone].add([i], weight, "REPLACE")
    mod = obj.modifiers.new("Horse skeleton", "ARMATURE")
    mod.object = arm
    return obj


def loft(name, rings, material, arm, weights, sides=16):
    """Connected elliptical rings along Y: (y, z, half width, half height)."""
    vertices = []
    for y, z, w, h in rings:
        for i in range(sides):
            a = math.tau * i / sides
            vertices.append((w * math.cos(a), y, z + h * math.sin(a)))
    faces = [tuple(reversed(range(sides)))]
    for j in range(len(rings) - 1):
        for i in range(sides):
            n = (i + 1) % sides
            faces.append((j*sides+i, j*sides+n, (j+1)*sides+n, (j+1)*sides+i))
    faces.append(tuple((len(rings)-1)*sides+i for i in range(sides)))
    return mesh(name, vertices, [tuple(reversed(f)) for f in faces], material, arm, weights)


def ellipsoid(name, center, radius, material, arm, bone, segments=16, rings=10):
    bpy.ops.mesh.primitive_uv_sphere_add(segments=segments, ring_count=rings, location=center)
    obj = bpy.context.object
    obj.name = name
    obj.scale = radius
    bpy.ops.object.transform_apply(location=True, rotation=False, scale=True)
    obj.parent = arm
    obj.data.materials.append(material)
    for p in obj.data.polygons:
        p.use_smooth = True
    obj.vertex_groups.new(name=bone).add(list(range(len(obj.data.vertices))), 1, "REPLACE")
    obj.modifiers.new("Horse skeleton", "ARMATURE").object = arm
    return obj


def tube(name, points, radii, material, arm, bone, sides=10):
    vertices = []
    for j, p in enumerate(points):
        p = Vector(p)
        direction = Vector(points[min(j+1, len(points)-1)]) - Vector(points[max(0, j-1)])
        basis = direction.to_track_quat("Z", "Y").to_matrix()
        rx, ry = radii[j]
        for i in range(sides):
            a = math.tau * i / sides
            vertices.append(p + basis @ Vector((rx*math.cos(a), ry*math.sin(a), 0)))
    faces = [tuple(reversed(range(sides)))]
    for j in range(len(points)-1):
        for i in range(sides):
            n = (i+1) % sides
            faces.append((j*sides+i, j*sides+n, (j+1)*sides+n, (j+1)*sides+i))
    faces.append(tuple((len(points)-1)*sides+i for i in range(sides)))
    return mesh(name, vertices, faces, material, arm, lambda _: {bone: 1})


LEGS = {
    "FL": (-.19, .54, 1.42, False), "FR": (.19, .54, 1.42, False),
    "HL": (-.20, -.56, 1.40, True), "HR": (.20, -.56, 1.40, True),
}


def joint(hip, end, length_a, length_b, bend):
    """Two-link IK in the sagittal plane, with an explicit anatomical bend."""
    delta = end - hip
    distance = delta.length
    if not abs(length_a-length_b) < distance < length_a+length_b:
        raise ValueError(f"Unreachable leg: {distance:.4f} / {length_a:.4f}+{length_b:.4f}")
    direction = delta.normalized()
    along = (length_a**2 - length_b**2 + distance**2)/(2*distance)
    across = math.sqrt(max(0, length_a**2 - along**2))
    side = Vector((0, -direction.z, direction.y)) * bend
    return hip + direction*along + side*across


def leg_points(name, y_offset=0, lift=0, body=None, fold=0, roll=0, adjust=None):
    x, y, z, hind = LEGS[name]
    hip = Vector((x, y, z))
    if body is not None:
        hip = body @ hip
    ankle = Vector((x, (-.57 if hind else .46)+y_offset, .14+lift))
    if adjust is not None:
        ankle += adjust
    toe = ankle + Matrix.Rotation(roll, 3, "X") @ Vector((0,.035,-.10))
    if hind:
        dy = max(-.29, min(.18, -.055-y_offset*.35-fold*.10))
        hock = ankle + Vector((0,dy,math.sqrt(.35**2-dy**2)))
        knee = joint(hip,hock,.42,.62,1)
        return [hip,knee,hock,ankle,toe]
    lower = max((ankle-hip).length-.43+.001, .959-fold*.28)
    lower = min(.959,lower)
    elbow = joint(hip,ankle,.43,lower,-1)
    carpus = joint(elbow,ankle,.51,.45,1)
    return [hip,elbow,carpus,ankle,toe]


def smooth(a, b, value):
    t = max(0,min(1,(value-a)/(b-a)))
    return t*t*(3-2*t)


def segment_distance(point, a, b):
    axis = b-a
    t = max(0,min(1,(point-a).dot(axis)/axis.length_squared))
    return (point-(a+axis*t)).length


def skin_weights(point):
    """Continuous thigh/body and joint weights on the fused skin."""
    if point.y > .40 and point.z > 1.31:
        neck = smooth(.33,.77,point.y)*smooth(1.28,1.58,point.z)*(1-smooth(.17,.31,abs(point.x)))
        head = smooth(.76,1.02,point.y)
        return {"body":1-neck,"neck":neck*(1-head),"head":neck*head}
    name = min(LEGS, key=lambda n: (point.x-LEGS[n][0])**2+(point.y-LEGS[n][1])**2)
    points = leg_points(name)
    distances = [(segment_distance(point,points[i],points[i+1]),i) for i in range(len(points)-1)]
    blend = (1-smooth(.90,1.25,point.z))*smooth(.055,.12,abs(point.x))
    blend *= 1-smooth(.12,.28,min(d for d,_ in distances))
    if point.z < .78:
        blend = 1  # only the free limbs exist below the belly
    closest = sorted(distances)[:2]
    raw = [(1/max(.025,d)**4,i) for d,i in closest]
    total = sum(w for w,_ in raw)
    return {"body":1-blend,**{name+str(i):blend*w/total for w,i in raw}}


def continuous_body(arm, material, points_material, white):
    """Union the anatomical volumes before rigging: one closed skin, no limb caps."""
    parts = [o for o in bpy.context.scene.objects if o.type=="MESH" and material in list(o.data.materials)]
    bpy.ops.object.select_all(action="DESELECT")
    for obj in parts:
        for mod in list(obj.modifiers):
            obj.modifiers.remove(mod)
        obj.select_set(True)
    bpy.context.view_layer.objects.active = parts[0]
    bpy.ops.object.join()
    body = bpy.context.object
    body.name = "Horse skin"
    remesh = body.modifiers.new("Connected anatomical skin","REMESH")
    remesh.mode = "VOXEL"
    remesh.voxel_size = .014
    remesh.use_smooth_shade = True
    bpy.ops.object.modifier_apply(modifier=remesh.name)
    soften = body.modifiers.new("Muscle transitions","SMOOTH")
    soften.factor,soften.iterations = .7,5
    bpy.ops.object.modifier_apply(modifier=soften.name)
    bm = bmesh.new()
    bm.from_mesh(body.data)
    bmesh.ops.recalc_face_normals(bm,faces=list(bm.faces))
    bm.to_mesh(body.data)
    bm.free()
    body.data.materials.append(points_material)
    body.data.materials.append(white)
    for face in body.data.polygons:
        center = sum((body.data.vertices[i].co for i in face.vertices),Vector())/len(face.vertices)
        # Bay points below the carpus/hock, and one real near-hind sock.
        if center.x < -.07 and center.y < -.15 and center.z < .25:
            face.material_index = 2
        elif center.z < (.43 if center.y < 0 else .51):
            face.material_index = 1
    body.vertex_groups.clear()
    groups = {bone.name:body.vertex_groups.new(name=bone.name) for bone in arm.data.bones}
    for vertex in body.data.vertices:
        for name,weight in skin_weights(vertex.co).items():
            if weight > 1e-8:
                groups[name].add([vertex.index],weight,"REPLACE")
    body.modifiers.new("Horse skeleton","ARMATURE").object = arm
    return body


def validate(arm):
    body = bpy.data.objects["Horse skin"]
    bm = bmesh.new()
    bm.from_mesh(body.data)
    remaining = set(bm.verts)
    components = 0
    while remaining:
        todo = [remaining.pop()]
        components += 1
        while todo:
            v = todo.pop()
            for edge in v.link_edges:
                other = edge.other_vert(v)
                if other in remaining:
                    remaining.remove(other)
                    todo.append(other)
    open_edges = sum(not e.is_manifold for e in bm.edges)
    bm.free()
    error = max(abs(sum(g.weight for g in v.groups)-1) for v in body.data.vertices)
    assert components==1 and open_edges==0 and error<1e-5,(components,open_edges,error)
    return {"skin_components":components,"non_manifold_edges":open_edges,
        "vertices":len(body.data.vertices),"weight_error":error,"bones":len(arm.data.bones)}


def build(material):
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete(use_global=False)
    data = bpy.data.armatures.new("Horse")
    arm = bpy.data.objects.new("Horse", data)
    bpy.context.scene.collection.objects.link(arm)
    bpy.context.view_layer.objects.active = arm
    arm.select_set(True)
    bpy.ops.object.mode_set(mode="EDIT")
    def bone(name, a, b, parent=None):
        item = data.edit_bones.new(name)
        item.head, item.tail = a, b
        if parent:
            item.parent = data.edit_bones[parent]
        return item
    bone("body", (0, 0, 1.1), (0, .45, 1.1))
    bone("neck", (0, .40, 1.30), (0, .86, 1.83), "body")
    bone("head", (0, .86, 1.83), (0, 1.23, 1.58), "neck")
    bone("tail", (0, -.70, 1.40), (0, -.90, .95), "body")
    for name in LEGS:
        points = leg_points(name)
        for i in range(len(points)-1):
            bone(name+str(i), points[i], points[i+1], "body" if i==0 else name+str(i-1))
    bpy.ops.object.mode_set(mode="OBJECT")
    coat, dark, hoof, white, eye, nose = [material[k] for k in ("coat", "hair", "hoof", "white", "eye", "nose")]
    loft("Barrel and haunches", [(-.76,1.31,.08,.16),(-.65,1.29,.25,.27),
        (-.45,1.23,.34,.33),(-.14,1.20,.35,.34),(.20,1.22,.32,.34),
        (.43,1.28,.29,.32),(.60,1.31,.19,.24),(.66,1.34,.06,.12)], coat, arm, lambda _: {"body":1})
    ellipsoid("Breast",(0,.50,1.19),(.25,.24,.28),coat,arm,"body")
    loft("Neck", [(.30,1.34,.22,.19),(.48,1.49,.215,.26),(.65,1.67,.17,.26),
        (.80,1.82,.115,.17),(.91,1.87,.105,.12)], coat, arm,
        lambda p: {"body":1-min(1,max(0,(p.y-.30)/.48)), "neck":min(1,max(0,(p.y-.30)/.48))})
    loft("Long face and muzzle", [(.77,1.85,.075,.11),(.86,1.88,.135,.16),
        (.99,1.82,.12,.16),(1.12,1.69,.09,.13),(1.27,1.59,.10,.09),
        (1.34,1.57,.09,.065)], coat, arm, lambda _: {"head":1})
    ellipsoid("Soft muzzle", (0,1.29,1.56), (.103,.085,.075), nose, arm, "head")
    for sign in (-1,1):
        ellipsoid("Cheek", (sign*.10,.91,1.77), (.075,.10,.105), coat, arm, "head")
        ellipsoid("Eye lid", (sign*.124,.94,1.87), (.019,.032,.028), dark, arm, "head")
        ellipsoid("Eye", (sign*.139,.948,1.874), (.008,.017,.017), eye, arm, "head")
        ellipsoid("Nostril", (sign*.087,1.313,1.582), (.012,.023,.015), dark, arm, "head")
        tube("Ear", [(sign*.085,.81,1.97),(sign*.12,.80,2.075),(sign*.135,.81,2.15)],
            [(.042,.039),(.034,.026),(.004,.004)], coat, arm, "head")
        tube("Ear inner", [(sign*.085,.839,1.98),(sign*.12,.828,2.07),(sign*.134,.819,2.13)],
            [(.018,.004),(.016,.004),(.002,.002)], nose, arm, "head", 6)
    # Narrow blaze on the front of the face, modelled on its surface, not a decal float.
    mesh("Blaze", [(-.018,.901,2.031),(.018,.901,2.031),(-.026,1.063,1.936),(.026,1.063,1.936),
        (-.023,1.218,1.785),(.023,1.218,1.785),(-.018,1.32,1.641),(.018,1.32,1.641)],
        [(0,1,3,2),(2,3,5,4),(4,5,7,6)], white, arm, lambda _: {"head":1})
    tube("Mane", [(0,.32,1.56),(0,.49,1.74),(0,.64,1.89),(0,.78,1.99),(0,.87,1.99)],
        [(.055,.055),(.06,.075),(.055,.075),(.045,.055),(.035,.04)], dark, arm, "neck")
    tube("Forelock", [(0,.85,1.99),(0,.95,1.97),(0,1.01,1.90)],
        [(.044,.04),(.047,.035),(.006,.005)], dark, arm, "head")
    tube("Tail", [(0,-.70,1.40),(0,-.85,1.27),(0,-.93,.95),(0,-.98,.58),(.015,-.98,.38)],
        [(.065,.07),(.072,.08),(.080,.07),(.065,.055),(.015,.02)], dark, arm, "tail", 14)
    for name in LEGS:
        points = leg_points(name)
        hind = LEGS[name][3]
        radii = [.18,.12,.055,.043] if hind else [.16,.095,.055,.043]
        for i in range(len(points)-2):
            a, b = points[i], points[i+1]
            tube(name+" limb "+str(i), [a,b], [(radii[i],radii[i]*.90),(radii[i+1],radii[i+1]*.95)],
                coat, arm, name+str(i), 12)
            ellipsoid(name+" joint "+str(i), b, (radii[i+1],radii[i+1],radii[i+1]*1.12), coat, arm, name+str(i))
        # A small white near-hind sock makes real opposite views distinguishable.
        hoof_bone = name+str(len(points)-2)
        p = points[-2]
        tube(name+" pastern", [p+Vector((0,0,.025)),p+Vector((0,.015,-.055))],
            [(.048,.048),(.047,.055)], white if name=="HL" else coat, arm, hoof_bone)
        # Flat sole, tapered wall and a forward toe; no round plates under the legs.
        vertices = [p+Vector((x,y,z)) for z,w,back,front in [(-.14,.072,-.048,.098),(-.045,.058,-.040,.060)]
            for x,y in [(-w,back),(w,back),(w,front),(-w,front)]]
        mesh(name+" hoof",vertices,[(3,2,1,0),(4,5,6,7),(0,1,5,4),(1,2,6,5),(2,3,7,6),(3,0,4,7)],
            hoof,arm,lambda _,b=hoof_bone:{b:1})
    continuous_body(arm,coat,dark,white)
    return arm


def orient(arm, name, head, tail):
    bone = arm.pose.bones[name]
    # Preserve the bind roll. A fresh track quaternion can turn a limb by 180°,
    # which rigid cylinders hid but which tears a weighted thigh out of the rump.
    rest = bone.bone
    turn = (rest.tail_local-rest.head_local).rotation_difference(tail-head)
    basis = turn.to_matrix().to_4x4() @ rest.matrix_local.to_3x3().to_4x4()
    basis.translation = head
    bone.matrix = basis


def foot_path(clip, t, name):
    hind = LEGS[name][3]
    if clip not in ("walk","run"):
        return 0,0,0,0,True
    if clip == "walk":
        touchdown = {"HL":0,"FL":.25,"HR":.5,"FR":.75}[name]
        stance,travel,front,height = .65,1.12,.36,.16 if hind else .14
    else:
        # Hind-hind, fore-fore, then suspension: the reference is gallop, not trot.
        touchdown = {"HL":.88,"HR":0,"FR":.24,"FL":.36}[name]
        stance,travel,front,height = .28,3.25,.44,.44 if hind else .48
    phase = (t-touchdown) % 1
    if phase < stance:
        offset = front-travel*phase
        # Flat through most of support; lift the heel at push-off.
        roll = math.radians(32*smooth(stance*.72,stance,phase))
        return offset,0,0,roll,True
    u = (phase-stance)/(1-stance)
    # Hermite endpoints keep the hoof moving backwards at lift-off and landing.
    back = front-travel*stance
    velocity = -travel*(1-stance)
    offset = (2*u**3-3*u*u+1)*back+(u**3-2*u*u+u)*velocity+(-2*u**3+3*u*u)*front+(u**3-u*u)*velocity
    lift = height*math.sin(math.pi*u)**1.3
    fold = math.sin(math.pi*u)*(.36 if clip=="walk" else 1)
    roll = math.radians(32*(1-u)-58*math.sin(math.pi*u))
    return offset,lift,fold,roll,False


def sole(arm, name):
    obj = bpy.data.objects[name+" hoof"]
    evaluated = obj.evaluated_get(bpy.context.evaluated_depsgraph_get())
    inverse = arm.matrix_world.inverted()
    points = [inverse @ (obj.matrix_world @ v.co) for v in evaluated.data.vertices]
    low = min(p.z for p in points)
    contact = [p for p in points if p.z < low+.001]
    return low,sum(p.y for p in contact)/len(contact)


def pose(arm, clip, t):
    for bone in arm.pose.bones:
        bone.matrix_basis = Matrix.Identity(4)
    bob = .008*math.cos(math.tau*t*2) if clip=="walk" else (.035*math.cos(math.tau*(t-.18)) if clip=="run" else .003*math.sin(math.tau*t))
    body = arm.pose.bones["body"]
    body.location.z = bob
    body.rotation_mode = "XYZ"
    body.rotation_euler.x = math.radians(1.2*math.sin(math.tau*(t-.1))) if clip=="run" else 0
    bpy.context.view_layer.update()
    body_transform = body.matrix @ body.bone.matrix_local.inverted()
    contacts = {}
    for name in LEGS:
        offset,lift,fold,roll,planted = foot_path(clip,t,name)
        base_y = -.57 if LEGS[name][3] else .46
        adjust = Vector((0,0,0))
        for attempt in range(2):
            points = leg_points(name,offset,lift,body_transform,fold,roll,adjust)
            for i in range(len(points)-1):
                orient(arm,name+str(i),points[i],points[i+1])
                bpy.context.view_layer.update()
            low,contact_y = sole(arm,name)
            adjust += Vector((0,base_y+offset+.025-contact_y,lift-low))
        low,contact_y = sole(arm,name)
        assert abs(low-lift)<.002,(clip,t,name,low,lift)
        contacts[name] = {"planted":planted,"lift":lift,"sole_z":low,"y":contact_y}
    arm.pose.bones["neck"].rotation_mode = "XYZ"
    arm.pose.bones["head"].rotation_mode = "XYZ"
    arm.pose.bones["tail"].rotation_mode = "XYZ"
    if clip == "graze":
        # Rotate the neck from the withers until the muzzle reaches the pasture.
        arm.pose.bones["neck"].rotation_euler.x = math.radians(-121+2*math.sin(t*math.tau))
        arm.pose.bones["head"].rotation_euler.x = math.radians(60)
    else:
        arm.pose.bones["neck"].rotation_euler.x = math.radians((2.5 if clip=="walk" else 1.5)*math.sin(t*math.tau))
        arm.pose.bones["head"].rotation_euler.x = math.radians(1.2*math.cos(t*math.tau))
    arm.pose.bones["tail"].rotation_euler.y = math.radians(5*math.sin(t*math.tau))
    arm.pose.bones["tail"].rotation_euler.x = math.radians(-36+5*math.sin(t*math.tau)) if clip=="run" else 0
    bpy.context.view_layer.update()
    return contacts
