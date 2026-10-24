"""Create + tune the physics asset that ragdolls jnt_fuse (the rag) in hands.

Discovery (editor_probe_phys.py): this drop exposes NO body/constraint arrays
on PhysicsAsset, no SkeletalBodySetup/PhysicsConstraintTemplate classes, and
PhysicsAssetFactory is dialog-gated. But SkeletalMeshEditorSubsystem has
create_physics_asset(mesh) — engine builds bodies+constraints per skinned
bone — and the created objects are reachable as package subobjects
(load_object "pkg.Name:Sub_N", the material-graph trick). get_constraints()
is exposed for the templates.

Tuning:
  - jnt_offset body: KINEMATIC anchor
  - jnt_fuse body:   SIMULATED, gravity, collision off, damped, light ->
                     per-body simulated = dangly-bit ragdoll, no runtime calls
  - constraint:      pendulum swings 75deg, spin 15deg, mapped onto MEASURED
                     bone axes (Blender FBX bones are Y-down-the-bone, NOT
                     UE's X convention — assuming X put the ballast sideways:
                     rag settled "hard right" and teetered on the pivot)

Thrown bottle = static twin, no bones: lua pins the material DroopDir.
Runs inside editor_headless_all.py after the SK reimport. Sentinel PHYS_DONE.
"""

import unreal

PLUGIN = "/MolotovBottle"
SK_PATH = f"{PLUGIN}/SK_MolotovBottle"
FUSE = "jnt_fuse"
ANCHOR = "jnt_offset"

sk = unreal.EditorAssetLibrary.load_asset(SK_PATH)
assert sk, "SK_MolotovBottle missing"

down_local = None  # world-down expressed in jnt_fuse ref-pose bone space
try:
    skel = sk.get_editor_property("skeleton")
    pose = unreal.AnimPoseExtensions.get_reference_pose(skel)
    names = [str(n) for n in unreal.AnimPoseExtensions.get_bone_names(pose)]
    unreal.log(f"[phys] skeleton={skel.get_path_name()} bones={names}")
    t = unreal.AnimPoseExtensions.get_bone_pose(pose, FUSE, unreal.AnimPoseSpaces.WORLD)
    down_local = unreal.MathLibrary.quat_unrotate_vector(
        t.rotation, unreal.Vector(0.0, 0.0, -1.0)
    ).normal()
    unreal.log(f"[phys] fuse ref rot={t.rotation} down_local={down_local}")
except Exception as e:
    unreal.log_warning(f"[phys] bone dump: {e}")
assert down_local, "PHYS_FAIL: could not measure fuse bone axes"


def find_bodies(pa_obj):
    pkg = pa_obj.get_path_name().rsplit(".", 1)[0]
    name = pa_obj.get_name()
    found = {}
    for i in range(64):
        for pat in (f"SkeletalBodySetup_{i}", f"BodySetup_{i}"):
            bs = unreal.load_object(None, f"{pkg}.{name}:{pat}")
            if bs:
                try:
                    found.setdefault(str(bs.get_editor_property("bone_name")), bs)
                except Exception:
                    pass
    return found


sub = unreal.get_editor_subsystem(unreal.SkeletalMeshEditorSubsystem)
pa = sk.get_editor_property("physics_asset")
if pa and FUSE not in find_bodies(pa):
    # stale generation (bone was under MinBoneSize) — rebuild from scratch
    stale = pa.get_path_name().rsplit(".", 1)[0]
    sk.set_editor_property("physics_asset", None)
    unreal.EditorAssetLibrary.delete_asset(stale)
    unreal.log(f"[phys] deleted stale {stale}")
    pa = None
if not pa:
    pa = sub.create_physics_asset(sk)
    unreal.log(f"[phys] created: {pa.get_path_name() if pa else None}")
assert pa, "PHYS_FAIL: create_physics_asset returned none"
pa_pkg = pa.get_path_name().rsplit(".", 1)[0]
unreal.log(f"[phys] physics asset: {pa.get_path_name()}")

bodies = find_bodies(pa)
unreal.log(f"[phys] bodies by bone: {sorted(bodies)}")
fuse_bs = bodies.get(FUSE)
anchor_bs = bodies.get(ANCHOR)
assert fuse_bs, "PHYS_FAIL: no body generated for jnt_fuse (check skin weights)"

if anchor_bs:
    anchor_bs.set_editor_property(
        "physics_type", unreal.PhysicsType.PHYS_TYPE_KINEMATIC
    )
fuse_bs.set_editor_property("physics_type", unreal.PhysicsType.PHYS_TYPE_SIMULATED)
for bs in filter(None, (anchor_bs, fuse_bs)):
    try:
        bs.set_editor_property(
            "collision_reponse", unreal.BodyCollisionResponse.BODY_COLLISION_DISABLED
        )
    except Exception as e:
        unreal.log_warning(f"[phys] collision off: {e}")

fi = fuse_bs.get_editor_property("default_instance")
for prop, val in [
    ("angular_damping", 4.0),
    ("linear_damping", 1.0),
    ("override_mass", True),
    ("mass_in_kg_override", 0.1),
    ("enable_gravity", True),
]:
    try:
        fi.set_editor_property(prop, val)
    except Exception as e:
        unreal.log_warning(f"[phys] fuse body {prop}: {e}")
fuse_bs.set_editor_property("default_instance", fi)

# --- replace the auto geom: it spans the phys-helper verts (giant capsule,
# COM ABOVE the joint = inverted pendulum jammed at the cone edge). Hang a
# small sphyl 7cm along the MEASURED down-bone axis instead. ---
for bone, bs in ((ANCHOR, anchor_bs), (FUSE, fuse_bs)):
    if not bs:
        continue
    ag = bs.get_editor_property("agg_geom")
    for elems in ("sphyl_elems", "sphere_elems", "box_elems"):
        try:
            arr = ag.get_editor_property(elems)
            for el in arr:
                try:
                    unreal.log(
                        f"[phys] {bone} auto {elems}: "
                        f"c={el.get_editor_property('center')} "
                        f"r={el.get_editor_property('rotation')}"
                    )
                except Exception:
                    unreal.log(f"[phys] {bone} auto {elems}: {el}")
        except Exception:
            pass
try:
    ag = fuse_bs.get_editor_property("agg_geom")
    sp = unreal.KSphylElem()
    sp.set_editor_property(
        "center",
        unreal.Vector(down_local.x * 7.0, down_local.y * 7.0, down_local.z * 7.0),
    )
    # sphyl long axis = its local Z; aim it down-bone
    sp.set_editor_property("rotation", unreal.MathLibrary.make_rot_from_z(down_local))
    sp.set_editor_property("radius", 2.5)
    sp.set_editor_property("length", 10.0)
    ag.set_editor_property("sphyl_elems", [sp])
    ag.set_editor_property("sphere_elems", [])
    ag.set_editor_property("box_elems", [])
    fuse_bs.set_editor_property("agg_geom", ag)
    unreal.log(f"[phys] fuse ballast sphyl along {down_local}")
except Exception as e:
    unreal.log_warning(f"[phys] agg_geom replace: {e}")

# --- tune the generated fuse constraint's limits (frames follow the child
# bone's ref frame): spin about the cloth's long axis stays tight, the two
# pendulum swings get the wide cone. UE maps swing1=Z, swing2=Y, twist=X. ---
SPIN, SWING = 15.0, 75.0
ax, ay, az = abs(down_local.x), abs(down_local.y), abs(down_local.z)
if ax >= ay and ax >= az:
    s1, s2, tw = SWING, SWING, SPIN  # long axis = X (twist)
elif ay >= az:
    s1, s2, tw = SWING, SPIN, SWING  # long axis = Y (swing2)
else:
    s1, s2, tw = SPIN, SWING, SWING  # long axis = Z (swing1)
tuned = 0
lib = unreal.ConstraintInstanceBlueprintLibrary
accs = pa.get_constraints(includes_terminated=True)
unreal.log(f"[phys] constraints: {len(accs)}")
for acc in accs:
    try:
        lib.set_angular_limits(
            acc,
            unreal.AngularConstraintMotion.ACM_LIMITED,
            s1,
            unreal.AngularConstraintMotion.ACM_LIMITED,
            s2,
            unreal.AngularConstraintMotion.ACM_LIMITED,
            tw,
        )
        tuned += 1
        unreal.log(f"[phys] constraint tuned: swing1={s1} swing2={s2} twist={tw}")
    except Exception as e:
        unreal.log_warning(f"[phys] constraint tune: {e}")
assert tuned, "PHYS_FAIL: no constraint tuned"

if sk.get_editor_property("physics_asset") != pa:
    sk.set_editor_property("physics_asset", pa)
unreal.EditorAssetLibrary.save_asset(SK_PATH, only_if_is_dirty=False)
saved = unreal.EditorAssetLibrary.save_asset(pa_pkg, only_if_is_dirty=False)
unreal.log(f"[phys] bodies={sorted(bodies)} constraints_tuned={tuned} saved={saved}")
unreal.log("PHYS_DONE")
