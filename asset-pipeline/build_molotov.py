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

# --- hanging tail: a plain rectangle of cloth, pinned into the mouth and
# draped deterministically against the glass. (Blender's cloth sim at 6 cm
# scale either exploded on self-collision or wrung the sheet into a rope —
# the authored centerline IS the physical answer, so shape it directly.)
rag_w = 0.056  # cloth width
hang_len = 0.150  # free cloth below the lip
tail_top = top_z + 0.004  # droop-weight anchor, shared with the flame colors
theta0 = 0.0  # side of the bottle the rag hangs toward
radial_v = Vector((math.cos(theta0), math.sin(theta0), 0))
tangent_v = Vector((-math.sin(theta0), math.cos(theta0), 0))

# centerline rows: scrunched pin inside the neck -> arc OVER the lip ->
# 45-ish diagonal past the neck -> plumb sheet riding just off the body
out_r = max_r + 0.004
lip_r = prof[-1] + 0.003 if prof[-1] > 0 else 0.012
rows = []  # (center, half_width, pinned)
pin_steps, lip_steps = 3, 2
for i in range(pin_steps + 1):
    f = i / pin_steps
    c = Vector((cx, cy, top_z - 0.010 + 0.008 * f)) + radial_v * (0.002 * f)
    rows.append((c, 0.006 + 0.002 * f, True))
for i in range(1, lip_steps + 1):  # clear the glass rim with headroom
    f = i / lip_steps
    c = Vector((cx, cy, top_z - 0.002 + 0.004 * f)) + radial_v * (
        0.002 + (lip_r - 0.002) * f
    )
    rows.append((c, 0.008 + 0.004 * f, False))
diag_z = 0.025  # kept: shells cut above this; fire starts past the lip arc


# below the lip the cloth falls plumb, lands on the glass where it widens, and
# never re-enters where it narrows: radial = running max of the glass profile
# (cloth length is budgeted along the drape path, not z)
def glass_r(z):
    if z <= lo.z:
        return prof[0]
    return prof[min(slices - 1, int((z - lo.z) / height * slices))]


standoff = 0.0035
n_hang = 30
seg = hang_len / n_hang
z_cur = top_z + 0.002
run_gr = max(lip_r - 0.003, 0.008)
r_prev = lip_r
arc_len, next_row, z_step = 0.0, seg, 0.0015
plumb_z = None  # where the drape clears the shoulder and hangs straight
while arc_len < hang_len:
    z_nxt = z_cur - z_step
    run_gr = max(run_gr, glass_r(z_nxt))
    if plumb_z is None and run_gr >= max_r - 1e-5:
        plumb_z = z_nxt
    r_nxt = run_gr + standoff
    arc_len += math.hypot(z_step, r_nxt - r_prev)
    if arc_len >= next_row:
        hw = 0.012 + (rag_w / 2 - 0.012) * min(1.0, arc_len / 0.04)
        rows.append((Vector((cx, cy, z_nxt)) + radial_v * r_nxt, hw, False))
        next_row += seg
    z_cur, r_prev = z_nxt, r_nxt
if plumb_z is None:
    plumb_z = top_z - 0.05

cols = 15
# drape character, all scaled by hang fraction so the pin stays put:
CUP = 0.004  # edges curl back toward the glass (cloth cups)
RIPPLE = 0.0032  # wavy folds, distributed up the sheet
SWAY = 0.004  # sheet drifts sideways as it falls
CORNER = 0.003  # hem corners sag below the center
mesh = bpy.data.meshes.new("rag_tail")
verts, faces = [], []
for c, hw, _ in rows:
    g = max(0.0, min(1.0, (top_z - c.z) / hang_len))
    for k in range(cols):
        s = k / (cols - 1) * 2 - 1
        r_off = (
            -CUP * s * s
            + RIPPLE * math.sin(s * 2.5 * math.pi + 0.6)
            + 0.0015 * math.sin(9.0 * c.z / hang_len) * math.sin(3.1 * s + 1.7)
        ) * g
        t_off = SWAY * g * g
        z_off = -CORNER * s * s * g * g
        p = c + tangent_v * (hw * s + t_off) + radial_v * r_off
        verts.append((p.x, p.y, p.z + z_off))
for i in range(len(rows) - 1):
    for k in range(cols - 1):
        a = i * cols + k
        faces.append((a, a + 1, a + cols + 1, a + cols))
mesh.from_pydata(verts, [], faces)
arc = [0.0]
for i in range(1, len(rows)):
    arc.append(arc[-1] + (rows[i][0] - rows[i - 1][0]).length)
uv = mesh.uv_layers.new(name="UVMap")
for poly in mesh.polygons:
    for li in poly.loop_indices:
        vi = mesh.loops[li].vertex_index
        row, col = vi // cols, vi % cols
        # U runs DOWN the tail: MikkTSpace tangents then point along the cloth,
        # giving the material a skinned droop axis (component transform doesn't
        # follow the hand bone, so Transform(Local->World) was a dead end)
        uv.data[li].uv = (arc[row] / arc[-1], col / (cols - 1))
mesh.update()
tail = bpy.data.objects.new("rag_tail", mesh)
bpy.context.collection.objects.link(tail)

hem_z = min(v.co.z for v in tail.data.vertices)
print(f"TRACE drape: hem_z={hem_z:.4f} target~{top_z - hang_len:.4f}")

# fire shells offset along +normal: make the drape's normals face away from
# the glass first (grid winding leaves them pointing inward)
mean_out = sum(
    v.normal.dot(Vector((v.co.x - cx, v.co.y - cy, 0.0))) for v in tail.data.vertices
)
if mean_out < 0:
    bm = bmesh.new()
    bm.from_mesh(tail.data)
    bmesh.ops.reverse_faces(bm, faces=bm.faces)
    bm.to_mesh(tail.data)
    bm.free()
    tail.data.update()
sim_me = tail.data.copy()  # pre-solidify drape = the fire shells' substrate
solid = tail.modifiers.new("solid", "SOLIDIFY")
solid.thickness = 0.005
solid.offset = 1  # thicken away from the glass: the sim surface rests on it
with bpy.context.temp_override(
    object=tail, active_object=tail, selected_objects=[tail]
):
    bpy.ops.object.modifier_apply(modifier="solid")
# round the solidify rim: a 90-degree slab edge reads knife-sharp in FP;
# angle limit keeps the bevel off the pleated cloth faces
bev = tail.modifiers.new("bev", "BEVEL")
bev.width = 0.0015
bev.segments = 1
bev.limit_method = "ANGLE"
bev.angle_limit = math.radians(60)
with bpy.context.temp_override(
    object=tail, active_object=tail, selected_objects=[tail]
):
    bpy.ops.object.modifier_apply(modifier="bev")
# smooth shade = shared normals = UE welds verts -> ONE mikk tangent per vert;
# flat faces split every vert, per-face tangents tear the droop WPO into shards
for p in tail.data.polygons:
    p.use_smooth = True
rag_parts.append(tail)

# vertex colors drive the droop WPO: the drape is fully MODELED now, so droop
# must be ZERO on the curved top (over-lip arc/shoulder — rest-flare there
# tore the cloth into shards, the bat-wing lesson amplified) and only ramp in
# on the straight plumb sheet where the droop axis is coherent. G = shell
# sign: radial side test, stable on the plumb sheet (the per-vert outward
# test jittered 0/1 where normals point up, flinging neighbors apart)
tail.data.update()
tail_col = tail.data.color_attributes.new(
    name="Col", type="FLOAT_COLOR", domain="POINT"
)
for i, vtx in enumerate(tail.data.vertices):
    hang = min(1.0, max(0.0, (plumb_z - vtx.co.z) / 0.10))
    sgn = 1.0 if vtx.normal.dot(radial_v) >= 0 else 0.0
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
sheath_mat = bpy.data.materials.new("M_SheathFlame")
make_distinct(sheath_mat, (0.1, 0.5, 1.0, 1.0))
flame_parts = []


def make_flame_cards(
    prefix, center, base_z, f_h, f_w, f_rows=6, center_fn=None, ang_off=0.0
):
    for k, ang in enumerate((0.0, 60.0, 120.0)):
        theta = math.radians(ang + ang_off)
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
make_flame_cards("flame_card", (cx, cy), f_base, 0.14, 0.11, f_rows=7)


# --- fire shells: the simmed drape duplicated and puffed out along its own
# normals — the bonfire flipbook burns exactly on the cloth's real shape; two
# layers give parallax depth. Replaces the hand-placed panels and the 16 card
# clusters that chased the old procedural drape.
def make_fire_shell(name, off):
    me = sim_me.copy()
    bm = bmesh.new()
    bm.from_mesh(me)
    bm.verts.ensure_lookup_table()
    cut_row = pin_steps + 1 + lip_steps  # fire starts past the lip, not inside
    cut = cut_row * cols
    bmesh.ops.delete(bm, geom=[v for v in bm.verts if v.index < cut], context="VERTS")
    bm.to_mesh(me)
    bm.free()
    me.update()
    for v in me.vertices:
        v.co += v.normal * off
    # flipbook UVs: U across the cloth; Blender V=0 at the hem (FBX import
    # flips V -> UE 1-at-bottom = flame frame base at the hem, fire flows up)
    u_start = arc[cut_row] / arc[-1]
    for d in me.uv_layers[0].data:
        u, v2 = d.uv
        d.uv = (v2, 1.0 - (u - u_start) / (1.0 - u_start))
    me.normals_split_custom_set([(0.0, 0.0, 1.0)] * len(me.loops))  # flame axis
    ob = bpy.data.objects.new(name, me)
    bpy.context.collection.objects.link(ob)
    ob.data.materials.clear()
    ob.data.materials.append(sheath_mat)
    flame_parts.append(ob)


make_fire_shell("sheath_in", 0.008)
make_fire_shell("sheath_out", 0.015)

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
    if part.name.startswith("sheath_"):
        base_z = min(v.co.z for v in part.data.vertices)
        part_h = max(1e-6, max(v.co.z for v in part.data.vertices) - base_z)
        for i, vtx in enumerate(part.data.vertices):
            r_val = min(1.0, max(0.0, (tail_top - vtx.co.z) / 0.14))
            t_h = (vtx.co.z - base_z) / part_h
            a_val = min(1.0, max(0.0, (t_h - 0.18) / 0.5))  # blue roots -> red body
            ca.data[i].color = (r_val, 1.0, (vtx.co.z - base_z) / 0.20, a_val)
    elif part.name.startswith(("flame_", "tipflame_")):
        is_tip = part.name.startswith("tipflame_")
        base_z = min(v.co.z for v in part.data.vertices)
        part_h = max(1e-6, max(v.co.z for v in part.data.vertices) - base_z)
        for i, vtx in enumerate(part.data.vertices):
            r_val = min(1.0, max(0.0, (tail_top - vtx.co.z) / 0.14)) if is_tip else 0.0
            t_h = (vtx.co.z - base_z) / part_h
            # A: blue alcohol burn where the flame roots into the cloth,
            # orange only where it has risen clear of it. Cap: the plug bulge
            # hides everything below t_h~0.15, so the blue must sit ABOVE it
            # to be visible at all — blue to 30%, full orange from 75%
            if is_tip:
                a_val = 0.75 * min(1.0, max(0.0, (t_h - 0.30) / 0.45))
            else:
                a_val = min(1.0, max(0.0, (t_h - 0.30) / 0.45))
            ca.data[i].color = (r_val, 1.0, (vtx.co.z - base_z) / 0.20, a_val)
    else:
        for d in ca.data:
            d.color = (0.0, 1.0, 0.0, 1.0)

# --- phys helpers: two sub-pixel triangles weighted to jnt_fuse ---
# UE's physics generator culls bones whose dominant-vert cloud half-diagonal
# is under MinBoneSize (20cm, not settable via python) and merges their verts
# into the parent; the rag cloud is ~11cm. These stretch the cloud past the
# filter, symmetric about the mesh bounds center so the FP mid-body grip
# solve (GetLocalBounds center) is unmoved. Stripped from the SM twin.
helper_parts = []
for hi, hz in enumerate((0.429, -0.091)):  # bounds center 0.169 +/- 0.26
    hme = bpy.data.meshes.new(f"phys_helper_{hi}")
    e = 0.00005
    hme.from_pydata([(cx, cy, hz), (cx + e, cy, hz), (cx, cy + e, hz)], [], [(0, 1, 2)])
    hme.materials.append(bottle.data.materials[0])
    hob = bpy.data.objects.new(f"phys_helper_{hi}", hme)
    bpy.context.collection.objects.link(hob)
    for gname in ("jnt_fuse", "phys_helper"):
        g = hob.vertex_groups.new(name=gname)
        g.add((0, 1, 2), 1.0, "REPLACE")
    helper_parts.append(hob)

# --- join rag + flame into bottle ---
# tag the fuse-riding parts BEFORE the join (groups merge by name): the rag
# drape and its fire shells skin to jnt_fuse so a future physics body can
# swing them; plug, cap flames, and glass stay rigid on jnt_offset
for part in [tail] + [p for p in flame_parts if p.name.startswith("sheath_")]:
    fvg = part.vertex_groups.new(name="jnt_fuse")
    fvg.add(range(len(part.data.vertices)), 1.0, "REPLACE")
bpy.ops.object.select_all(action="DESELECT")
bottle.select_set(True)
for part in rag_parts + flame_parts + helper_parts:
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

# --- fuse joint: child bone at the mouth so the rag can swing as a unit
# (reusable anchor for any future fused object) ---
bpy.ops.object.select_all(action="DESELECT")
armature.select_set(True)
bpy.context.view_layer.objects.active = armature
bpy.ops.object.mode_set(mode="EDIT")
eb = armature.data.edit_bones.new("jnt_fuse")
eb.head = (cx, cy, top_z)
eb.tail = (cx, cy, top_z - 0.22)
eb.parent = armature.data.edit_bones["jnt_offset"]
# FBX drops leaf-bone tails (re-imports at default length) and UE measures
# bone length by CHILD JOINT distance — without this end joint the physics
# generator's MinBoneSize (20cm) filter skips jnt_fuse. No weights on it.
ee = armature.data.edit_bones.new("jnt_fuse_end")
ee.head = (cx, cy, top_z - 0.22)
ee.tail = (cx, cy, top_z - 0.25)
ee.parent = eb
bpy.ops.object.mode_set(mode="OBJECT")

# --- rigid skin: fuse-tagged verts to jnt_fuse, everything else jnt_offset ---
fuse_vg = bottle.vertex_groups.get("jnt_fuse")
fuse_idx = fuse_vg.index if fuse_vg else -1
free = [
    v.index
    for v in bottle.data.vertices
    if not any(g.group == fuse_idx for g in v.groups)
]
vg = bottle.vertex_groups.new(name="jnt_offset")
vg.add(free, 1.0, "REPLACE")
print(
    f"TRACE skin: jnt_offset={len(free)} jnt_fuse={len(bottle.data.vertices) - len(free)}"
)
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
# strip the phys helpers first: box collision + bounds must hug the bottle
hvg = bottle.vertex_groups.get("phys_helper")
if hvg:
    bpy.ops.object.select_all(action="DESELECT")
    bottle.select_set(True)
    bpy.context.view_layer.objects.active = bottle
    bottle.vertex_groups.active_index = hvg.index
    bpy.ops.object.mode_set(mode="EDIT")
    bpy.ops.mesh.select_mode(type="VERT")
    bpy.ops.mesh.select_all(action="DESELECT")
    bpy.ops.object.vertex_group_select()
    bpy.ops.mesh.delete(type="VERT")
    bpy.ops.object.mode_set(mode="OBJECT")
    bottle.vertex_groups.remove(hvg)
    print(f"TRACE phys helpers stripped: verts={len(bottle.data.vertices)}")
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
