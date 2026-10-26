# Render the molotov inventory icon from the built bottle+rag mesh, using the
# real vanilla label art and our own rag cloth. Strip the flames first — the
# bottle is unlit until it's thrown:
#   blender -b out/molotov_bottle.blend -P preview_noflame.py -P build_icon.py
# The right-hand cant that matches the vanilla icon is applied in compose_icons.py.
import math
import os

import bpy
from mathutils import Vector

OUT_DIR = r"c:\Code\westerfield.cloud\Gaming\stalker-2\asset-pipeline\out"
OUT = os.path.join(OUT_DIR, "T_MolotovIcon_raw.png")
VANILLA = os.path.join(OUT_DIR, "vanilla")
RES = 768

LABEL_MAT = "MI_cns_cossacks_vodka_01_02"
RAG_MAT = "MI_molotov_rag"
GLASS_MAT = "MI_cns_cossacks_vodka_01_glass"

ob = bpy.data.objects["SK_MolotovBottle"]
mw = ob.matrix_world


def robust_span(values):
    """Bounds that ignore the phys_helper outliers build_molotov.py welds on.

    They sit ~30cm above the bottle as a small CLUSTER, so comparing only
    adjacent values stops short. Scan the outer band for a real gap, but refuse
    to drop more than 1% of the points so a seam in the glass can't clip the
    base off. bound_box and flat percentiles are both useless here.
    """
    vals = sorted(values)
    n = len(vals)
    if n < 20:
        return vals[0], vals[-1]
    gap = (vals[-1] - vals[0]) * 0.06
    max_drop = max(2, int(n * 0.01))
    hi = n - 1
    for i in range(n - 1, n - max_drop - 1, -1):
        if vals[i] - vals[i - 1] > gap:
            hi = i - 1
            break
    lo = 0
    for i in range(0, max_drop):
        if vals[i + 1] - vals[i] > gap:
            lo = i + 1
            break
    return vals[lo], vals[hi]


# preview_noflame.py deletes the flame FACES but leaves their vertices orphaned,
# and those strays sit well outside the bottle — measure only what still renders.
used = set()
for poly in ob.data.polygons:
    used.update(poly.vertices)
pts = [mw @ ob.data.vertices[i].co for i in sorted(used)]
xlo, xhi = robust_span(p.x for p in pts)
ylo, yhi = robust_span(p.y for p in pts)
zlo, zhi = robust_span(p.z for p in pts)
center = Vector(((xlo + xhi) / 2, (ylo + yhi) / 2, (zlo + zhi) / 2))
height = zhi - zlo
width = max(xhi - xlo, yhi - ylo)

# Aim at the printed face instead of guessing an azimuth: average the label
# polygons' normals and stand the camera off along that direction.
label_idx = next(
    (i for i, m in enumerate(ob.data.materials) if m and m.name == LABEL_MAT), None
)
facing = Vector((0.0, -1.0, 0.0))
if label_idx is not None:
    n3 = mw.to_3x3()
    acc = Vector((0.0, 0.0, 0.0))
    for poly in ob.data.polygons:
        if poly.material_index == label_idx:
            acc += (n3 @ poly.normal) * poly.area
    acc.z = 0.0
    if acc.length > 1e-9:
        facing = acc.normalized()


def build_mat(mat, texture=None, flat=(0.6, 0.5, 0.4, 1.0), gain=0.0):
    mat.use_nodes = True
    nt = mat.node_tree
    nt.nodes.clear()
    out_node = nt.nodes.new("ShaderNodeOutputMaterial")
    bsdf = nt.nodes.new("ShaderNodeBsdfPrincipled")
    bsdf.inputs["Roughness"].default_value = 0.5
    bsdf.inputs["Metallic"].default_value = 0.0
    if texture and os.path.exists(texture):
        img = nt.nodes.new("ShaderNodeTexImage")
        img.image = bpy.data.images.load(texture, check_existing=True)
        src = img.outputs["Color"]
        if gain:
            # T_RagCloth is a very dark albedo. Scale VALUE rather than adding
            # brightness - adding lifts all channels equally and turns the
            # brown to grey.
            hsv = nt.nodes.new("ShaderNodeHueSaturation")
            hsv.inputs["Value"].default_value = gain
            hsv.inputs["Saturation"].default_value = 1.25
            nt.links.new(src, hsv.inputs["Color"])
            src = hsv.outputs["Color"]
        nt.links.new(src, bsdf.inputs["Base Color"])
    else:
        bsdf.inputs["Base Color"].default_value = flat
    nt.links.new(bsdf.outputs["BSDF"], out_node.inputs["Surface"])


for mat in ob.data.materials:
    if not mat:
        continue
    if mat.name == LABEL_MAT:
        build_mat(mat, os.path.join(VANILLA, "T_cns_cossacks_vodka_01_02_D.png"))
    elif mat.name == RAG_MAT:
        build_mat(mat, os.path.join(OUT_DIR, "T_RagCloth.png"), gain=3.2)
    elif mat.name == GLASS_MAT:
        build_mat(mat, flat=(0.055, 0.105, 0.065, 1.0))

scene = bpy.context.scene
for engine in ("BLENDER_EEVEE_NEXT", "BLENDER_EEVEE"):
    try:
        scene.render.engine = engine
        break
    except TypeError:
        continue

scene.render.resolution_x = RES
scene.render.resolution_y = RES
scene.render.resolution_percentage = 100
scene.render.film_transparent = True  # inventory icons need alpha
scene.render.image_settings.file_format = "PNG"
scene.render.image_settings.color_mode = "RGBA"

cam_data = bpy.data.cameras.new("icon_cam")
cam_data.type = "ORTHO"
cam_data.ortho_scale = max(height, width) * 1.08
cam = bpy.data.objects.new("icon_cam", cam_data)
bpy.context.collection.objects.link(cam)
scene.camera = cam

dist = max(height, width) * 4.0
cam.location = center + facing * dist + Vector((0.0, 0.0, height * 0.06))
cam.rotation_euler = (center - cam.location).to_track_quat("-Z", "Y").to_euler()

# Light from the camera side so the label stays legible instead of edge-lit.
key = bpy.data.objects.new("key", bpy.data.lights.new("key", "SUN"))
key.data.energy = 4.5
key.rotation_euler = (
    math.radians(55),
    0.0,
    math.atan2(facing.y, facing.x) + math.radians(25),
)
bpy.context.collection.objects.link(key)

fill = bpy.data.objects.new("fill", bpy.data.lights.new("fill", "SUN"))
fill.data.energy = 2.0
fill.rotation_euler = (
    math.radians(75),
    0.0,
    math.atan2(facing.y, facing.x) - math.radians(70),
)
bpy.context.collection.objects.link(fill)

scene.render.filepath = OUT
bpy.ops.render.render(write_still=True)
print(
    f"ICON_RENDERED {OUT} z=[{zlo:.3f},{zhi:.3f}] x=[{xlo:.3f},{xhi:.3f}] "
    f"y=[{ylo:.3f},{yhi:.3f}] h={height:.3f} w={width:.3f} "
    f"ortho={cam_data.ortho_scale:.3f} centre={tuple(round(c,3) for c in center)} "
    f"facing={tuple(round(c,2) for c in facing)}"
)
