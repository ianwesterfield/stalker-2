# Render the Bottle Prep Kit inventory icon from the built bottle+rag mesh.
# Chain the flame stripper first so the kit reads as supplies, not a lit bottle:
#   blender -b out/molotov_bottle.blend -P preview_noflame.py -P build_icon.py
import math
import os

import bpy
from mathutils import Vector

OUT_DIR = r"c:\Code\westerfield.cloud\Gaming\stalker-2\asset-pipeline\out"
OUT = os.path.join(OUT_DIR, "T_MolotovKitIcon.png")
RES = 512

ob = bpy.data.objects["SK_MolotovBottle"]

# Percentile bounds, not bound_box: build_molotov.py welds two sub-pixel
# phys_helper triangles out at z=0.429 to survive the PhysicsAsset bone filter,
# and they drag the real bbox (and its centre) well off the bottle.
pts = [ob.matrix_world @ v.co for v in ob.data.vertices]


def span(axis):
    vals = sorted(p[axis] for p in pts)
    return vals[int(len(vals) * 0.02)], vals[int(len(vals) * 0.98)]


xlo, xhi = span(0)
ylo, yhi = span(1)
zlo, zhi = span(2)
center = Vector(((xlo + xhi) / 2, (ylo + yhi) / 2, (zlo + zhi) / 2))
height = zhi - zlo
width = max(xhi - xlo, yhi - ylo)

# Rebuild the materials outright: the glass slot has no Principled node to poke,
# so name-lookup tinting left it rendering black.
colors = {
    "MI_cns_cossacks_vodka_01_glass": (0.10, 0.21, 0.13, 1.0),  # dark bottle glass
    "MI_cns_cossacks_vodka_01_02": (0.78, 0.60, 0.28, 1.0),  # amber label
    "MI_molotov_rag": (0.86, 0.84, 0.78, 1.0),  # off-white bandage
}
for mat in ob.data.materials:
    if not mat or mat.name not in colors:
        continue
    mat.use_nodes = True
    nt = mat.node_tree
    nt.nodes.clear()
    out_node = nt.nodes.new("ShaderNodeOutputMaterial")
    bsdf = nt.nodes.new("ShaderNodeBsdfPrincipled")
    bsdf.inputs["Base Color"].default_value = colors[mat.name]
    bsdf.inputs["Roughness"].default_value = 0.55
    bsdf.inputs["Metallic"].default_value = 0.0
    nt.links.new(bsdf.outputs["BSDF"], out_node.inputs["Surface"])

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

key = bpy.data.objects.new("key", bpy.data.lights.new("key", "SUN"))
key.data.energy = 4.0
key.rotation_euler = (math.radians(55), 0, math.radians(35))
bpy.context.collection.objects.link(key)

fill = bpy.data.objects.new("fill", bpy.data.lights.new("fill", "SUN"))
fill.data.energy = 1.6
fill.rotation_euler = (math.radians(70), 0, math.radians(215))
bpy.context.collection.objects.link(fill)

cam_data = bpy.data.cameras.new("icon_cam")
cam_data.type = "ORTHO"
cam_data.ortho_scale = max(height, width) * 1.06  # margin inside the grid cell
cam = bpy.data.objects.new("icon_cam", cam_data)
bpy.context.collection.objects.link(cam)
scene.camera = cam

# three-quarter view with a little elevation so the bottle reads as round
angle = math.radians(55)
dist = max(height, width) * 4.0
cam.location = center + Vector(
    (dist * math.cos(angle), dist * math.sin(angle), height * 0.18)
)
cam.rotation_euler = (center - cam.location).to_track_quat("-Z", "Y").to_euler()

scene.render.filepath = OUT
bpy.ops.render.render(write_still=True)
print(f"ICON_RENDERED {OUT} h={height:.3f} w={width:.3f}")
