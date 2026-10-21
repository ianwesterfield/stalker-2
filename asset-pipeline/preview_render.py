# Render turnaround previews of the built molotov bottle.
# Run: blender -b out/molotov_bottle.blend -P preview_render.py
import bpy
import math
import os
from mathutils import Vector

OUT_DIR = r"c:\Code\westerfield.cloud\Gaming\stalker-2\asset-pipeline\out"

bottle = bpy.data.objects["SK_MolotovBottle"]
center = sum((bottle.matrix_world @ Vector(c) for c in bottle.bound_box), Vector()) / 8

# distinct viewport colors per slot
colors = {
    "MI_cns_cossacks_vodka_01_glass": (0.35, 0.5, 0.35, 1),
    "MI_cns_cossacks_vodka_01_02": (0.75, 0.7, 0.55, 1),
    "MI_molotov_rag": (0.7, 0.2, 0.15, 1),
}
for mat in bottle.data.materials:
    if mat and mat.name in colors:
        mat.use_nodes = True
        bsdf = mat.node_tree.nodes.get("Principled BSDF")
        if bsdf:
            bsdf.inputs["Base Color"].default_value = colors[mat.name]

sun = bpy.data.objects.new("sun", bpy.data.lights.new("sun", "SUN"))
sun.data.energy = 3
sun.rotation_euler = (math.radians(50), 0, math.radians(30))
bpy.context.collection.objects.link(sun)

cam_data = bpy.data.cameras.new("cam")
cam = bpy.data.objects.new("cam", cam_data)
bpy.context.collection.objects.link(cam)
bpy.context.scene.camera = cam

scene = bpy.context.scene
scene.render.engine = "BLENDER_EEVEE"
scene.render.resolution_x = 700
scene.render.resolution_y = 900
scene.world = bpy.data.worlds.new("w")
scene.world.use_nodes = True
scene.world.node_tree.nodes["Background"].inputs[0].default_value = (
    0.15,
    0.15,
    0.17,
    1,
)

dist = 0.55
for i, angle in enumerate([20, 110, 200, 290]):
    a = math.radians(angle)
    cam.location = center + Vector((dist * math.cos(a), dist * math.sin(a), 0.08))
    direction = center - cam.location
    cam.rotation_euler = direction.to_track_quat("-Z", "Y").to_euler()
    scene.render.filepath = os.path.join(OUT_DIR, f"preview_{i}.png")
    bpy.ops.render.render(write_still=True)
    print(f"rendered preview_{i}.png")
print("done")
