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
  - jnt_fuse.._04:   SIMULATED chain, gravity, collision off, mass tapering to
                     the hem, damping climbing to it -> cloth-like drape from
                     per-link pendulums, no runtime calls
  - constraints:     root cone 10deg (the mouth join must not gape), widening
                     to 45deg at the hem; linear LOCKED + projection on, which
                     kills the pull-away drift the single body suffered;
                     limits mapped onto MEASURED bone axes (Blender FBX bones
                     are Y-down-the-bone, NOT UE's X convention)

Thrown bottle = static twin, no bones: lua pins the material DroopDir.
Runs inside editor_headless_all.py after the SK reimport. Sentinel PHYS_DONE.
"""

import unreal

PLUGIN = "/MolotovBottle"
SK_PATH = f"{PLUGIN}/SK_MolotovBottle"
CHAIN = ["jnt_fuse", "jnt_fuse_01", "jnt_fuse_02", "jnt_fuse_03", "jnt_fuse_04"]
ANCHOR = "jnt_offset"
FUSE = CHAIN[0]

sk = unreal.EditorAssetLibrary.load_asset(SK_PATH)
assert sk, "SK_MolotovBottle missing"

down_local = {}  # per-bone: world-down expressed in ref-pose bone space
link_len = {}  # per-bone: distance to its child joint (cm)
try:
    skel = sk.get_editor_property("skeleton")
    pose = unreal.AnimPoseExtensions.get_reference_pose(skel)
    names = [str(n) for n in unreal.AnimPoseExtensions.get_bone_names(pose)]
    unreal.log(f"[phys] skeleton={skel.get_path_name()} bones={names}")
    child_of = dict(zip(CHAIN, CHAIN[1:] + ["jnt_fuse_end"]))
    for bone in CHAIN:
        try:
            t = unreal.AnimPoseExtensions.get_bone_pose(
                pose, bone, unreal.AnimPoseSpaces.WORLD
            )
            down_local[bone] = unreal.MathLibrary.quat_unrotate_vector(
                t.rotation, unreal.Vector(0.0, 0.0, -1.0)
            ).normal()
            child = child_of[bone]
            if child in names:
                ct = unreal.AnimPoseExtensions.get_bone_pose(
                    pose, child, unreal.AnimPoseSpaces.WORLD
                )
                # unreal.Transform exposes .translation (NOT .location)
                link_len[bone] = (ct.translation - t.translation).length()
            unreal.log(
                f"[phys] {bone} down_local={down_local[bone]} len={link_len.get(bone)}"
            )
        except Exception as e:
            unreal.log_warning(f"[phys] {bone} measure: {e}")
except Exception as e:
    unreal.log_warning(f"[phys] bone dump: {e}")
assert down_local.get(FUSE), "PHYS_FAIL: could not measure fuse bone axes"


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
if pa:
    have = find_bodies(pa)
    if any(b not in have for b in CHAIN):
        # stale generation (chain bodies absent). Do NOT delete in-session: the
        # Shipping commandlet AV'd inside Force Delete (2026-11-02) — the
        # pipeline pre-deletes the .uasset from disk before the editor boots,
        # so landing here means that guard was skipped.
        raise AssertionError(
            "PHYS_FAIL: stale physics asset lacks chain bodies "
            f"({[b for b in CHAIN if b not in have]}); delete "
            "SK_MolotovBottle_PhysicsAsset.uasset and re-run"
        )
if not pa:
    pa = sub.create_physics_asset(sk)
    unreal.log(f"[phys] created: {pa.get_path_name() if pa else None}")
assert pa, "PHYS_FAIL: create_physics_asset returned none"
pa_pkg = pa.get_path_name().rsplit(".", 1)[0]
unreal.log(f"[phys] physics asset: {pa.get_path_name()}")

bodies = find_bodies(pa)
unreal.log(f"[phys] bodies by bone: {sorted(bodies)}")
anchor_bs = bodies.get(ANCHOR)
missing = [b for b in CHAIN if b not in bodies]
assert not missing, f"PHYS_FAIL: no body for {missing} (check per-link helpers/weights)"

if anchor_bs:
    anchor_bs.set_editor_property(
        "physics_type", unreal.PhysicsType.PHYS_TYPE_KINEMATIC
    )
    try:
        anchor_bs.set_editor_property(
            "collision_reponse", unreal.BodyCollisionResponse.BODY_COLLISION_DISABLED
        )
    except Exception as e:
        unreal.log_warning(f"[phys] anchor collision off: {e}")

# chain bodies: simulated, no collision, light with a hem taper so the strip
# hangs instead of wagging; damping climbs toward the hem to kill jitter
for i, bone in enumerate(CHAIN):
    bs = bodies[bone]
    bs.set_editor_property("physics_type", unreal.PhysicsType.PHYS_TYPE_SIMULATED)
    try:
        bs.set_editor_property(
            "collision_reponse", unreal.BodyCollisionResponse.BODY_COLLISION_DISABLED
        )
    except Exception as e:
        unreal.log_warning(f"[phys] {bone} collision off: {e}")
    fi = bs.get_editor_property("default_instance")
    for prop, val in [
        ("angular_damping", 3.0 + 1.0 * i),
        ("linear_damping", 1.0),
        ("override_mass", True),
        ("mass_in_kg_override", max(0.02, 0.08 - 0.015 * i)),
        ("enable_gravity", True),
    ]:
        try:
            fi.set_editor_property(prop, val)
        except Exception as e:
            unreal.log_warning(f"[phys] {bone} body {prop}: {e}")
    bs.set_editor_property("default_instance", fi)

# --- replace the auto geom: it spans the phys-helper verts (giant capsule,
# COM ABOVE the joint = inverted pendulum jammed at the cone edge). Hang a
# small sphyl along each link's MEASURED down-bone axis instead, sized to the
# link so each body's COM sits mid-link. ---
for bone, bs in [(ANCHOR, anchor_bs)] + [(b, bodies[b]) for b in CHAIN]:
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
for bone in CHAIN:
    try:
        bs = bodies[bone]
        dl = down_local.get(bone) or down_local[FUSE]
        length = max(2.0, (link_len.get(bone) or 4.0) - 1.0)
        half = length / 2.0
        ag = bs.get_editor_property("agg_geom")
        sp = unreal.KSphylElem()
        sp.set_editor_property(
            "center", unreal.Vector(dl.x * half, dl.y * half, dl.z * half)
        )
        # sphyl long axis = its local Z; aim it down-bone
        sp.set_editor_property("rotation", unreal.MathLibrary.make_rot_from_z(dl))
        sp.set_editor_property("radius", 1.2)
        sp.set_editor_property("length", length)
        ag.set_editor_property("sphyl_elems", [sp])
        ag.set_editor_property("sphere_elems", [])
        ag.set_editor_property("box_elems", [])
        bs.set_editor_property("agg_geom", ag)
        unreal.log(f"[phys] {bone} sphyl len={length} along {dl}")
    except Exception as e:
        unreal.log_warning(f"[phys] {bone} agg_geom replace: {e}")

# --- tune the generated constraints (frames follow the child bone's ref
# frame). The ROOT link stays tight — the rag visibly tore away from the mouth
# when the single body had a 75-degree cone — and the cone widens down the
# chain; cumulative travel still folds the strip right over. Linear axes are
# explicitly LOCKED and projection snaps accumulated drift back every frame:
# the two together are the join-gap fix. UE maps swing1=Z, swing2=Y, twist=X.
PER_LINK = [(10.0, 4.0), (35.0, 8.0), (40.0, 10.0), (45.0, 12.0), (45.0, 12.0)]


def limits_for(bone, swing, spin):
    dl = down_local.get(bone) or down_local[FUSE]
    ax, ay, az = abs(dl.x), abs(dl.y), abs(dl.z)
    if ax >= ay and ax >= az:
        return swing, swing, spin  # long axis = X (twist)
    elif ay >= az:
        return swing, spin, swing  # long axis = Y (swing2)
    return spin, swing, swing  # long axis = Z (swing1)


tuned = 0
lib = unreal.ConstraintInstanceBlueprintLibrary
accs = pa.get_constraints(includes_terminated=True)
unreal.log(f"[phys] constraints: {len(accs)}")
for idx, acc in enumerate(accs):
    # generation order follows the bone hierarchy: offset->fuse, fuse->01, ...
    bone = CHAIN[min(idx, len(CHAIN) - 1)]
    swing, spin = PER_LINK[min(idx, len(PER_LINK) - 1)]
    s1, s2, tw = limits_for(bone, swing, spin)
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
        try:
            lib.set_linear_limits(
                acc,
                unreal.LinearConstraintMotion.LCM_LOCKED,
                unreal.LinearConstraintMotion.LCM_LOCKED,
                unreal.LinearConstraintMotion.LCM_LOCKED,
                0.0,
            )
        except Exception as e:
            unreal.log_warning(f"[phys] {bone} linear lock: {e}")
        for fn, args in (
            ("set_projection_params", (acc, True, 0.5, 2.0)),
            ("set_projection_enabled", (acc, True)),
        ):
            try:
                getattr(lib, fn)(*args)
                unreal.log(f"[phys] {bone} projection via {fn}")
                break
            except Exception:
                pass
        tuned += 1
        unreal.log(f"[phys] {bone} tuned: swing1={s1} swing2={s2} twist={tw}")
    except Exception as e:
        unreal.log_warning(f"[phys] constraint tune: {e}")
assert tuned >= len(CHAIN), f"PHYS_FAIL: tuned {tuned} < {len(CHAIN)} chain constraints"

if sk.get_editor_property("physics_asset") != pa:
    sk.set_editor_property("physics_asset", pa)
unreal.EditorAssetLibrary.save_asset(SK_PATH, only_if_is_dirty=False)
saved = unreal.EditorAssetLibrary.save_asset(pa_pkg, only_if_is_dirty=False)
unreal.log(f"[phys] bodies={sorted(bodies)} constraints_tuned={tuned} saved={saved}")
unreal.log("PHYS_DONE")
