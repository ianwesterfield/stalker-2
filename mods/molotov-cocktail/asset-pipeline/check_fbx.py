# Headless check: does out/SK_MolotovBottle.fbx carry exactly the bottle + rag
# material slots and the rag vertex colors? Round-trips through Blender's FBX
# importer and reports.
import os

import bpy
from mathutils import Vector

OUT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "out")

bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.fbx(filepath=os.path.join(OUT_DIR, "SK_MolotovBottle.fbx"))

meshes = [o for o in bpy.data.objects if o.type == "MESH"]
print(f"CHECK mesh objects: {[o.name for o in meshes]}")
ob = meshes[0]
me = ob.data
print(f"CHECK verts={len(me.vertices)} polys={len(me.polygons)}")
print(f"CHECK material slots: {[m.name if m else None for m in me.materials]}")

# color attribute
attrs = {a.name: (a.domain, a.data_type) for a in me.color_attributes}
print(f"CHECK color attributes: {attrs}")
if me.color_attributes:
    ca = me.color_attributes[0]
    vals = [tuple(round(c, 3) for c in d.color[:2]) for d in ca.data]
    r_nonzero = sum(1 for r, g in vals if r > 0.01)
    g_zero = sum(1 for r, g in vals if g < 0.5)
    print(f"CHECK color samples={len(vals)} R>0.01: {r_nonzero}  G<0.5: {g_zero}")
    print(f"CHECK R range: {min(v[0] for v in vals)} .. {max(v[0] for v in vals)}")
else:
    print("CHECK NO COLOR ATTRIBUTES — FBX lost them")

SLOTS = ["MI_cns_cossacks_vodka_01_glass", "MI_cns_cossacks_vodka_01_02", "MI_molotov_rag"]
slot_names = [m.name.split(".")[0] if m else None for m in me.materials]
assert slot_names == SLOTS, f"unexpected material slots {slot_names}"

# static twin: helpers stripped, same slots
bpy.ops.import_scene.fbx(filepath=os.path.join(OUT_DIR, "SM_MolotovBottle.fbx"))
sm = next(o for o in bpy.data.objects if o.type == "MESH" and o.name.startswith("SM_"))
sme = sm.data
print(f"CHECK SM verts={len(sme.vertices)} polys={len(sme.polygons)}")
# helpers are isolated triangles (3 verts each, one pair per chain bone): the
# strip must remove a positive multiple of 3 verts; zero diff = leaked helpers
helper_verts = len(me.vertices) - len(sme.vertices)
print(f"CHECK helper verts stripped: {helper_verts}")
assert helper_verts > 0 and helper_verts % 3 == 0, "phys helpers leaked into SM twin"
sm_slots = [m.name.split(".")[0] if m else None for m in sme.materials]
assert sm_slots == SLOTS, f"unexpected SM material slots {sm_slots}"
print("CHECK_DONE")
