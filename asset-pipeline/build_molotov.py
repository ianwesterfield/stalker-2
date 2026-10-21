# Build SK_MolotovBottle: cossack vodka mesh + rag, skinned to the RGD5 grenade rig.
# Run: blender -b -P build_molotov.py
import bpy
import bmesh
import math
import os
from mathutils import Vector

EXPORTS = r"C:\Tools\FModel\Output\Exports"
RGD5_GLB = os.path.join(EXPORTS, r"Stalker2\Content\_STALKER2\SkeletalMeshes\weapons\grenades\RGD5\SK_RGD5.glb")
ZG_GLB = os.path.join(EXPORTS, r"Stalker2\Mods\ZoneGrenades\Content\Meshes\SK_ZoneGrenadeBottle.glb")
SM_GLB = os.path.join(EXPORTS, r"Stalker2\Content\_Stalker_2\items\consumable\SM_cns_cossacks_vodka_01_c.glb")
OUT_DIR = r"c:\Code\westerfield.cloud\Gaming\stalker-2\asset-pipeline\out"

os.makedirs(OUT_DIR, exist_ok=True)


def wipe():
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete()


def import_glb(path):
    before = set(bpy.context.scene.objects)
    bpy.ops.import_scene.gltf(filepath=path)
    return [o for o in bpy.context.scene.objects if o not in before]


def world_bbox(obj):
    pts = [obj.matrix_world @ Vector(c) for c in obj.bound_box]
    lo = Vector((min(p.x for p in pts), min(p.y for p in pts), min(p.z for p in pts)))
    hi = Vector((max(p.x for p in pts), max(p.y for p in pts), max(p.z for p in pts)))
    return lo, hi


wipe()

# --- armature from SK_RGD5 ---
rgd5_objs = import_glb(RGD5_GLB)
armature = next(o for o in rgd5_objs if o.type == "ARMATURE")
for o in rgd5_objs:
    if o.type == "MESH":
        bpy.data.objects.remove(o, do_unlink=True)
bpy.data.orphans_purge(do_local_ids=True, do_linked_ids=True, do_recursive=True)

# --- ZoneGrenades bottle: placement reference only ---
zg_objs = import_glb(ZG_GLB)
zg_mesh = next(o for o in zg_objs if o.type == "MESH" and "Bottle" in o.name)
zg_lo, zg_hi = world_bbox(zg_mesh)
print(f"ZG bottle bbox: lo=({zg_lo.x:.4f},{zg_lo.y:.4f},{zg_lo.z:.4f}) hi=({zg_hi.x:.4f},{zg_hi.y:.4f},{zg_hi.z:.4f})")
for o in zg_objs:
    bpy.data.objects.remove(o, do_unlink=True)
bpy.data.orphans_purge(do_local_ids=True, do_linked_ids=True, do_recursive=True)

# --- cossack vodka mesh ---
sm_objs = import_glb(SM_GLB)
bottle = next(o for o in sm_objs if o.type == "MESH" and "vodka" in o.name)
for o in sm_objs:
    if o is not bottle:
        bpy.data.objects.remove(o, do_unlink=True)

sm_lo, sm_hi = world_bbox(bottle)
print(f"SM bottle bbox: lo=({sm_lo.x:.4f},{sm_lo.y:.4f},{sm_lo.z:.4f}) hi=({sm_hi.x:.4f},{sm_hi.y:.4f},{sm_hi.z:.4f})")

# align SM to ZG placement (xy centers, z bottoms)
delta = Vector((
    (zg_lo.x + zg_hi.x) / 2 - (sm_lo.x + sm_hi.x) / 2,
    (zg_lo.y + zg_hi.y) / 2 - (sm_lo.y + sm_hi.y) / 2,
    zg_lo.z - sm_lo.z,
))
bottle.location += delta
bpy.context.view_layer.update()
print(f"aligned SM by delta ({delta.x:.4f},{delta.y:.4f},{delta.z:.4f})")

# bake transform into verts
bottle.data.transform(bottle.matrix_world)
bottle.matrix_world.identity()
bpy.context.view_layer.update()

# rename material slots to match game materials (ZG order: glass, label)
slot_names = ["MI_cns_cossacks_vodka_01_glass", "MI_cns_cossacks_vodka_01_02"]
for i, mat in enumerate(bottle.data.materials):
    if i < len(slot_names) and mat:
        mat.name = slot_names[i]

# --- bottle shape analysis (for rag placement) ---
lo, hi = world_bbox(bottle)
cx, cy = (lo.x + hi.x) / 2, (lo.y + hi.y) / 2
top_z = hi.z
height = hi.z - lo.z
slices = 50
prof = [0.0] * slices
for v in bottle.data.vertices:
    z = v.co.z
    idx = min(slices - 1, max(0, int((z - lo.z) / height * slices)))
    r = math.hypot(v.co.x - cx, v.co.y - cy)
    prof[idx] = max(prof[idx], r)
max_r = max(prof)
print("radius profile (bottom→top): " + " ".join(f"{r*1000:.0f}" for r in prof))

# neck wrap sits ~3 cm below the mouth
wrap_z = top_z - 0.030
wrap_idx = min(slices - 1, int((wrap_z - lo.z) / height * slices))
neck_r = max(prof[wrap_idx], 0.008)
print(f"top_z={top_z:.4f} wrap_z={wrap_z:.4f} neck_r={neck_r*1000:.1f}mm max_r={max_r*1000:.1f}mm")

rag_mat = bpy.data.materials.new("MI_molotov_rag")
rag_parts = []

# --- rag wrap: knotted cloth around the neck ---
bpy.ops.mesh.primitive_torus_add(
    major_radius=neck_r + 0.0015, minor_radius=0.004,
    major_segments=16, minor_segments=8,
    location=(cx, cy, wrap_z), generate_uvs=True)
wrap = bpy.context.active_object
wrap.name = "rag_wrap"
wrap.scale.z = 1.4  # fatter vertically, like wrapped cloth
rag_parts.append(wrap)

# --- wick: cloth plug protruding from the mouth ---
bpy.ops.mesh.primitive_cylinder_add(
    radius=0.007, depth=0.035, vertices=10,
    location=(cx, cy + 0.002, top_z + 0.008), calc_uvs=True)
wick = bpy.context.active_object
wick.name = "rag_wick"
wick.rotation_euler = (math.radians(12), 0, 0)  # slight lean
rag_parts.append(wick)

# --- hanging tail strip, built by hand with UVs ---
segs, width0, width1, length = 12, 0.022, 0.011, 0.085
mesh = bpy.data.meshes.new("rag_tail")
verts, faces, uvs = [], [], []
for i in range(segs + 1):
    t = i / segs
    w = (width0 * (1 - t) + width1 * t) / 2
    sway = 0.006 * math.sin(t * math.pi * 1.5)
    x = cx + neck_r + 0.004 + 0.010 * t + sway
    z = wrap_z - length * t
    verts.append((x, cy - w, z))
    verts.append((x, cy + w, z))
for i in range(segs):
    a = i * 2
    faces.append((a, a + 1, a + 3, a + 2))
mesh.from_pydata(verts, [], faces)
uv = mesh.uv_layers.new(name="UVMap")
for poly in mesh.polygons:
    for li in poly.loop_indices:
        vi = mesh.loops[li].vertex_index
        row, side = vi // 2, vi % 2
        uv.data[li].uv = (side, 1 - row / segs)
mesh.update()
tail = bpy.data.objects.new("rag_tail", mesh)
bpy.context.collection.objects.link(tail)
solid = tail.modifiers.new("solid", "SOLIDIFY")
solid.thickness = 0.002
solid.offset = 0
with bpy.context.temp_override(object=tail, active_object=tail, selected_objects=[tail]):
    bpy.ops.object.modifier_apply(modifier="solid")
rag_parts.append(tail)

for part in rag_parts:
    part.data.materials.clear()
    part.data.materials.append(rag_mat)

# bake rag transforms
bpy.context.view_layer.update()
for part in rag_parts:
    part.data.transform(part.matrix_world)
    part.matrix_world.identity()

# --- join rag into bottle ---
bpy.ops.object.select_all(action="DESELECT")
bottle.select_set(True)
for part in rag_parts:
    part.select_set(True)
bpy.context.view_layer.objects.active = bottle
bpy.ops.object.join()
bottle.name = "SK_MolotovBottle"
bottle.data.name = "SK_MolotovBottle"

# --- rigid skin: everything to jnt_offset ---
vg = bottle.vertex_groups.new(name="jnt_offset")
vg.add(range(len(bottle.data.vertices)), 1.0, "REPLACE")
mod = bottle.modifiers.new("Armature", "ARMATURE")
mod.object = armature
bottle.parent = armature

# UE FBX convention: armature object named 'Armature' is stripped on import
armature.name = "Armature"

print(f"final mesh: {len(bottle.data.vertices)} verts, {len(bottle.data.polygons)} polys, "
      f"materials={[m.name for m in bottle.data.materials]}")

# --- save + export ---
blend_path = os.path.join(OUT_DIR, "molotov_bottle.blend")
bpy.ops.wm.save_as_mainfile(filepath=blend_path)

bpy.ops.object.select_all(action="DESELECT")
bottle.select_set(True)
armature.select_set(True)
fbx_path = os.path.join(OUT_DIR, "SK_MolotovBottle.fbx")
bpy.ops.export_scene.fbx(
    filepath=fbx_path,
    use_selection=True,
    object_types={"ARMATURE", "MESH"},
    add_leaf_bones=False,
    mesh_smooth_type="FACE",
    apply_scale_options="FBX_SCALE_UNITS",
    bake_anim=False,
)
print(f"exported {fbx_path}")
print("done")
