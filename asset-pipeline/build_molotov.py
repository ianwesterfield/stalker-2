# Build SK_MolotovBottle: cossack vodka mesh + rag, skinned to the RGD5 grenade rig.
# Run: blender -b -P build_molotov.py
import bpy
import bmesh
import math
import os
from mathutils import Matrix, Vector

EXPORTS = r"C:\Tools\FModel\Output\Exports"
RGD5_FBX = r"c:\Code\westerfield.cloud\Gaming\stalker-2\asset-pipeline\ref\Game\_STALKER2\SkeletalMeshes\weapons\grenades\RGD5\SK_RGD5.FBX"
ZG_GLB = os.path.join(
    EXPORTS, r"Stalker2\Mods\ZoneGrenades\Content\Meshes\SK_ZoneGrenadeBottle.glb"
)
SM_GLB = os.path.join(
    EXPORTS,
    r"Stalker2\Content\_Stalker_2\items\consumable\SM_cns_cossacks_vodka_01_c.glb",
)
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

# --- armature from editor-exported SK_RGD5 (authoritative bind pose; the
# glTF-converted rig skinned 25m off at runtime) ---
before = set(bpy.context.scene.objects)
bpy.ops.import_scene.fbx(filepath=RGD5_FBX)
rgd5_objs = [o for o in bpy.context.scene.objects if o not in before]
armature = next(o for o in rgd5_objs if o.type == "ARMATURE")
print(f"armature scale={tuple(armature.scale)} loc={tuple(armature.location)}")
for o in rgd5_objs:
    if o.type == "MESH":
        bpy.data.objects.remove(o, do_unlink=True)
bpy.data.orphans_purge(do_local_ids=True, do_linked_ids=True, do_recursive=True)
bpy.ops.object.select_all(action="DESELECT")
armature.select_set(True)
bpy.context.view_layer.objects.active = armature
# FBX importer stashes the cm->m unit conversion in delta_scale, which
# transform_apply ignores — bake the FULL world matrix into the bones
world = armature.matrix_world.copy()
bpy.ops.object.mode_set(mode="EDIT")
armature.data.transform(world)
bpy.ops.object.mode_set(mode="OBJECT")
armature.matrix_world.identity()
armature.delta_location = (0, 0, 0)
armature.delta_rotation_euler = (0, 0, 0)
armature.delta_scale = (1, 1, 1)
bpy.context.view_layer.update()
assert armature.matrix_world.to_scale()[0] == 1.0, "armature world scale not identity"
jb = armature.data.bones.get("jnt_offset")
print(f"jnt_offset head_local: {tuple(jb.head_local) if jb else 'MISSING'}")
print(f"bones: {sorted(b.name for b in armature.data.bones)}")

# --- ZoneGrenades bottle: placement reference only ---
zg_objs = import_glb(ZG_GLB)
zg_mesh = next(o for o in zg_objs if o.type == "MESH" and "Bottle" in o.name)
zg_lo, zg_hi = world_bbox(zg_mesh)
print(
    f"ZG bottle bbox: lo=({zg_lo.x:.4f},{zg_lo.y:.4f},{zg_lo.z:.4f}) hi=({zg_hi.x:.4f},{zg_hi.y:.4f},{zg_hi.z:.4f})"
)
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
print(
    f"SM bottle bbox: lo=({sm_lo.x:.4f},{sm_lo.y:.4f},{sm_lo.z:.4f}) hi=({sm_hi.x:.4f},{sm_hi.y:.4f},{sm_hi.z:.4f})"
)

# align SM to ZG placement (xy centers, z bottoms)
delta = Vector(
    (
        (zg_lo.x + zg_hi.x) / 2 - (sm_lo.x + sm_hi.x) / 2,
        (zg_lo.y + zg_hi.y) / 2 - (sm_lo.y + sm_hi.y) / 2,
        zg_lo.z - sm_lo.z,
    )
)
bottle.location += delta
bpy.context.view_layer.update()
print(f"aligned SM by delta ({delta.x:.4f},{delta.y:.4f},{delta.z:.4f})")

# bake transform into verts
bottle.data.transform(bottle.matrix_world)
bottle.matrix_world.identity()
bpy.context.view_layer.update()
print(f"TRACE after bake: dims={tuple(round(d,4) for d in bottle.dimensions)}")

# keep only the primary UV channel; extra channels union on join and bloat the
# cooked vertex buffers (editor showed 4 UV channels — suspect for invisibility)
while len(bottle.data.uv_layers) > 1:
    bottle.data.uv_layers.remove(bottle.data.uv_layers[-1])
bottle.data.uv_layers[0].name = "UVMap"

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
print(
    f"top_z={top_z:.4f} wrap_z={wrap_z:.4f} neck_r={neck_r*1000:.1f}mm max_r={max_r*1000:.1f}mm"
)

rag_mat = bpy.data.materials.new("MI_molotov_rag")


# bare identical materials dedupe in UE Interchange -> rag+flame sections merge
# into one slot; distinct principled colors keep them separate
def make_distinct(mat, rgba):
    mat.diffuse_color = rgba
    mat.use_nodes = True
    mat.node_tree.nodes["Principled BSDF"].inputs["Base Color"].default_value = rgba


make_distinct(rag_mat, (0.08, 0.07, 0.06, 1.0))
rag_parts = []

# --- rag plug: cloth stuffed into the mouth, bulging out ---
bpy.ops.mesh.primitive_uv_sphere_add(
    radius=0.0145,
    segments=12,
    ring_count=8,
    location=(cx, cy, top_z + 0.003),
    calc_uvs=True,
)
plug = bpy.context.active_object
plug.name = "rag_plug"
plug.scale = (1.0, 1.0, 0.65)  # squashed bulge, not a ball
for p in plug.data.polygons:
    p.use_smooth = True
rag_parts.append(plug)

# --- hanging tail: draped grid following the bottle contour ---
# fill gaps in the radius profile so any z can be sampled
filled = prof[:]
known = [i for i, r in enumerate(filled) if r > 0]
for i in range(slices):
    if filled[i] == 0:
        lo_i = max((k for k in known if k < i), default=None)
        hi_i = min((k for k in known if k > i), default=None)
        if lo_i is None:
            filled[i] = filled[hi_i]
        elif hi_i is None:
            filled[i] = filled[lo_i]
        else:
            f = (i - lo_i) / (hi_i - lo_i)
            filled[i] = filled[lo_i] * (1 - f) + filled[hi_i] * f


def radius_at(z):
    idx = (z - lo.z) / height * slices
    idx = min(slices - 1.001, max(0.0, idx))
    i0 = int(idx)
    f = idx - i0
    return filled[i0] * (1 - f) + filled[min(i0 + 1, slices - 1)] * f


segs, cols = 14, 7
width0, width1, length = 0.034, 0.024, 0.135
theta0, drift = 0.0, math.radians(35)  # slides around the bottle as it falls
mouth_r = 0.006  # emerges from inside the mouth
tail_top = top_z + 0.004
mesh = bpy.data.meshes.new("rag_tail")
verts, faces = [], []
for i in range(segs + 1):
    t = i / segs
    z = tail_top - length * t
    theta = theta0 + drift * t
    radial = Vector((math.cos(theta), math.sin(theta), 0))
    tangent = Vector((-math.sin(theta), math.cos(theta), 0))
    gap = 0.0015 + 0.0025 * t * t  # hangs slightly off the glass toward the hem
    # blend from inside the mouth out over the lip onto the glass
    blend = min(1.0, t / 0.18)
    r = mouth_r * (1 - blend) + (radius_at(min(z, top_z)) + gap) * blend
    w = (width0 * (1 - t) + width1 * t) / 2
    for c in range(cols):
        s = c / (cols - 1) * 2 - 1  # -1..1 across the strip
        sag = 0.005 * (1 - s * s) * t  # middle bellies out as it falls
        hem = 0.008 * t * abs(math.sin(s * 2.6 + 1.3))  # ragged bottom edge
        p = Vector((cx, cy, z - hem)) + radial * (r + sag) + tangent * (w * s)
        verts.append(tuple(p))
for i in range(segs):
    for c in range(cols - 1):
        a = i * cols + c
        faces.append((a, a + 1, a + cols + 1, a + cols))
mesh.from_pydata(verts, [], faces)
uv = mesh.uv_layers.new(name="UVMap")
for poly in mesh.polygons:
    for li in poly.loop_indices:
        vi = mesh.loops[li].vertex_index
        row, col = vi // cols, vi % cols
        # U runs DOWN the tail: MikkTSpace tangents then point along the cloth,
        # giving the material a skinned droop axis (component transform doesn't
        # follow the hand bone, so Transform(Local->World) was a dead end)
        uv.data[li].uv = (row / segs, col / (cols - 1))
mesh.update()
tail = bpy.data.objects.new("rag_tail", mesh)
bpy.context.collection.objects.link(tail)
solid = tail.modifiers.new("solid", "SOLIDIFY")
solid.thickness = 0.006
solid.offset = 0
with bpy.context.temp_override(
    object=tail, active_object=tail, selected_objects=[tail]
):
    bpy.ops.object.modifier_apply(modifier="solid")
# smooth shade = shared normals = UE welds verts -> ONE mikk tangent per vert;
# flat faces split every vert, per-face tangents tear the droop WPO into shards
for p in tail.data.polygons:
    p.use_smooth = True
rag_parts.append(tail)

# vertex colors drive the droop WPO: R = hang distance below the attach point
# (/14 cm), G = shell sign — solidify's inner shell has flipped normals, which
# would invert the material's cross(tangent, normal) hang axis
tail.data.update()
tail_col = tail.data.color_attributes.new(
    name="Col", type="FLOAT_COLOR", domain="POINT"
)
for i, vtx in enumerate(tail.data.vertices):
    hang = min(1.0, max(0.0, (tail_top - vtx.co.z) / 0.14))
    out = Vector((vtx.co.x - cx, vtx.co.y - cy, 0.0))
    sgn = 1.0 if out.length < 1e-6 or vtx.normal.dot(out) >= 0 else 0.0
    tail_col.data[i].color = (hang, sgn, 0.0, 1.0)

for part in rag_parts:
    part.data.materials.clear()
    part.data.materials.append(rag_mat)

# --- flame cards: three crossed, row-subdivided quads above the rag plug.
# Skinned geometry = follows every animation by construction; the material
# (unlit additive, noise-distorted gradient) supplies motion. Rows give the
# shader vertices to sway with World Position Offset.
flame_mat = bpy.data.materials.new("M_RagFlame")
make_distinct(flame_mat, (1.0, 0.45, 0.05, 1.0))
flame_parts = []


def make_flame_cards(prefix, center, base_z, f_h, f_w, f_rows=6, center_fn=None):
    for k, ang in enumerate((0.0, 60.0, 120.0)):
        theta = math.radians(ang)
        tang = Vector((math.cos(theta), math.sin(theta), 0))
        fm = bpy.data.meshes.new(f"{prefix}_{k}")
        vs, fs = [], []
        for r in range(f_rows + 1):
            t = r / f_rows
            z = base_z + f_h * t
            c = center_fn(z) if center_fn else center
            for s in (-1.0, 1.0):
                p = Vector((c[0], c[1], z)) + tang * (f_w / 2 * s)
                vs.append(tuple(p))
        for r in range(f_rows):
            a = r * 2
            fs.append((a, a + 1, a + 3, a + 2))
        fm.from_pydata(vs, [], fs)
        uvl = fm.uv_layers.new(name="UVMap")
        for poly in fm.polygons:
            for li in poly.loop_indices:
                vi = fm.loops[li].vertex_index
                row, side = vi // 2, vi % 2
                uvl.data[li].uv = (float(side), row / f_rows)  # v=0 base, v=1 tip
        fm.update()
        # hijack normals as the flame axis: material is unlit, and skinning rotates
        # normals, so WPO can read VertexNormalWS to re-point the flame at world-up
        fm.normals_split_custom_set([(0.0, 0.0, 1.0)] * len(fm.loops))
        card = bpy.data.objects.new(f"{prefix}_{k}", fm)
        bpy.context.collection.objects.link(card)
        card.data.materials.append(flame_mat)
        flame_parts.append(card)


# single flame cap: one wide cluster wrapping the plug — no satellite clusters,
# which read as extra wicks; roots sunk below the bulge so the base is hidden
f_base = top_z - 0.008
make_flame_cards("flame_card", (cx, cy), f_base, 0.14, 0.10, f_rows=7)


# faint blue alcohol burn down the wick (vertex alpha 0 marks the blue tint)
def wick_center(z):
    t_tail = min(1.0, max(0.0, (tail_top - z) / length))
    theta = theta0 + drift * t_tail
    radial = Vector((math.cos(theta), math.sin(theta), 0))
    gap = 0.0015 + 0.0025 * t_tail * t_tail
    r = radius_at(min(z, top_z)) + gap + 0.0035
    c = Vector((cx, cy, 0)) + radial * r
    return (c.x, c.y)


for frac, fh, fw, nrows in (
    (1.0, 0.055, 0.034, 4),
    (0.7, 0.045, 0.03, 3),
    (0.4, 0.038, 0.026, 3),
):
    zb = tail_top - length * frac
    make_flame_cards(
        f"tipflame_{int(frac * 100)}",
        None,
        zb - 0.003,
        fh,
        fw,
        f_rows=nrows,
        center_fn=wick_center,
    )

# bake rag transforms
bpy.context.view_layer.update()
for part in rag_parts + flame_parts:
    part.data.transform(part.matrix_world)
    part.matrix_world.identity()

# flame/droop data colors — R = droop weight (tip flame verts match the tail's
# per-vertex hang so the climbing fire stays glued to the swinging cloth),
# G = legacy shell sign, B = height above card base (/20 cm) for the bend scale
for part in [bottle, plug] + flame_parts:
    while part.data.color_attributes:
        part.data.color_attributes.remove(part.data.color_attributes[0])
    ca = part.data.color_attributes.new(name="Col", type="FLOAT_COLOR", domain="POINT")
    if part.name.startswith(("flame_", "tipflame_")):
        is_tip = part.name.startswith("tipflame_")
        base_z = min(v.co.z for v in part.data.vertices)
        a_val = 0.0 if is_tip else 1.0  # A: 1 = orange cap, 0 = blue alcohol burn
        for i, vtx in enumerate(part.data.vertices):
            r_val = min(1.0, max(0.0, (tail_top - vtx.co.z) / 0.14)) if is_tip else 0.0
            ca.data[i].color = (r_val, 1.0, (vtx.co.z - base_z) / 0.20, a_val)
    else:
        for d in ca.data:
            d.color = (0.0, 1.0, 0.0, 1.0)

# --- join rag + flame into bottle ---
bpy.ops.object.select_all(action="DESELECT")
bottle.select_set(True)
for part in rag_parts + flame_parts:
    part.select_set(True)
bpy.context.view_layer.objects.active = bottle
bpy.ops.object.join()
bottle.name = "SK_MolotovBottle"
bottle.data.name = "SK_MolotovBottle"
print(
    f"TRACE after join: dims={tuple(round(d,4) for d in bottle.dimensions)} scale={tuple(bottle.scale)}"
)

tri = bottle.modifiers.new("tri", "TRIANGULATE")
tri.keep_custom_normals = True
with bpy.context.temp_override(
    object=bottle, active_object=bottle, selected_objects=[bottle]
):
    bpy.ops.object.modifier_apply(modifier="tri")

# verify the flame-axis normals survived join + triangulate
flame_slot = [m.name for m in bottle.data.materials].index("M_RagFlame")
bottle.data.update()
for poly in bottle.data.polygons:
    if poly.material_index == flame_slot:
        n = bottle.data.corner_normals[poly.loop_indices[0]].vector
        print(f"TRACE flame normal: {tuple(round(v, 3) for v in n)}")
        assert n[2] > 0.99, "flame-axis custom normals lost"
        break

# --- rigid skin: everything to jnt_offset ---
vg = bottle.vertex_groups.new(name="jnt_offset")
vg.add(range(len(bottle.data.vertices)), 1.0, "REPLACE")
mod = bottle.modifiers.new("Armature", "ARMATURE")
mod.object = armature
bottle.parent = armature
bpy.context.view_layer.update()
print(
    f"TRACE after parent: dims={tuple(round(d,4) for d in bottle.dimensions)} arm_matrix_scale={tuple(round(v,4) for v in armature.matrix_world.to_scale())}"
)

# Blender absorbed the FBX root bone into the armature object; keeping its name
# makes UE re-create jnt_wpn_rgd5 as root (naming it 'Armature' would strip it)
assert armature.name == "jnt_wpn_rgd5", f"unexpected armature name {armature.name}"

print(
    f"final mesh: {len(bottle.data.vertices)} verts, {len(bottle.data.polygons)} polys, "
    f"uv_channels={len(bottle.data.uv_layers)}, "
    f"materials={[m.name for m in bottle.data.materials]}"
)

# --- save + export ---
blend_path = os.path.join(OUT_DIR, "molotov_bottle.blend")
bpy.ops.wm.save_as_mainfile(filepath=blend_path)

bpy.ops.object.select_all(action="DESELECT")
bottle.select_set(True)
armature.select_set(True)

# The game's importer scales GEOMETRY by the FBX unit header but reads BONE
# numerics raw: meter numerics cooked /100 bind matrices (invisible mesh),
# cm numerics under a meter header imported geometry 100x big. Match the
# UE-native convention exactly: cm numerics AND a cm unit header.
cm = Matrix.Scale(100.0, 4)
bpy.context.view_layer.objects.active = armature
bpy.ops.object.mode_set(mode="EDIT")
armature.data.transform(cm)
bpy.ops.object.mode_set(mode="OBJECT")
bottle.data.transform(cm)
bpy.context.scene.unit_settings.scale_length = 0.01
bpy.context.view_layer.update()
print(f"TRACE cm bake: dims={tuple(round(d, 2) for d in bottle.dimensions)}")

fbx_path = os.path.join(OUT_DIR, "SK_MolotovBottle.fbx")
bpy.ops.export_scene.fbx(
    filepath=fbx_path,
    use_selection=True,
    object_types={"ARMATURE", "MESH"},
    add_leaf_bones=False,
    mesh_smooth_type="FACE",
    use_tspace=True,
    colors_type="LINEAR",  # droop weights are data, not color — no sRGB curve
    # scene is now cm (scale_length 0.01): unit-aware export writes cm header
    # with the cm numerics untouched
    apply_unit_scale=True,
    apply_scale_options="FBX_SCALE_NONE",
    bake_anim=False,
)
print(f"exported {fbx_path}")

# --- static twin for world/thrown/ground mesh (same cm-baked data, no armature) ---
bpy.ops.object.select_all(action="DESELECT")
bottle.select_set(True)
bpy.context.view_layer.objects.active = bottle
bottle.name = "SM_MolotovBottle"
bottle.data.name = "SM_MolotovBottle"
sm_path = os.path.join(OUT_DIR, "SM_MolotovBottle.fbx")
bpy.ops.export_scene.fbx(
    filepath=sm_path,
    use_selection=True,
    object_types={"MESH"},
    mesh_smooth_type="FACE",
    use_tspace=True,
    colors_type="LINEAR",
    apply_unit_scale=True,
    apply_scale_options="FBX_SCALE_NONE",
    bake_anim=False,
)
print(f"exported {sm_path}")
print("done")
