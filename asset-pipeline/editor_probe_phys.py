"""One-boot API probe: what does THIS engine drop expose for PhysicsAsset,
body setups, constraints, and AnimPose? Prints [probe] lines."""

import unreal

reg = unreal.AssetRegistryHelpers.get_asset_registry()
reg.scan_paths_synchronous(
    ["/Game/_STALKER2/SkeletalMeshes/weapons"], force_rescan=True
)

pa = None
for ad in reg.get_assets_by_path(
    "/Game/_STALKER2/SkeletalMeshes/weapons", recursive=True
):
    if "PhysicsAsset" in str(getattr(ad, "asset_class_path", "")):
        pa = unreal.EditorAssetLibrary.load_asset(str(ad.package_name))
        if pa:
            unreal.log(f"[probe] loaded donor {ad.package_name}")
            break
assert pa, "no donor PA found"

unreal.log(f"[probe] PhysicsAsset dir: {[m for m in dir(pa) if not m.startswith('_')]}")

for prop in (
    "skeletal_body_setups",
    "body_setup",
    "body_setups",
    "bodies",
    "constraint_setup",
    "constraint_setups",
    "constraints",
    "preview_skeletal_mesh",
    "solver_settings",
):
    try:
        v = pa.get_editor_property(prop)
        try:
            n = len(v)
        except Exception:
            n = "?"
        unreal.log(f"[probe] pa.{prop} OK len={n} type={type(v).__name__}")
    except Exception as e:
        unreal.log(f"[probe] pa.{prop} FAIL {e}")

# class availability
for cls in (
    "SkeletalBodySetup",
    "BodySetup",
    "PhysicsConstraintTemplate",
    "KAggregateGeom",
    "KSphylElem",
    "ConstraintInstance",
    "ConstraintProfileProperties",
    "ConeConstraint",
    "TwistConstraint",
    "BodyInstance",
    "PhysicsType",
    "BodyCollisionResponse",
    "AngularConstraintMotion",
):
    unreal.log(f"[probe] unreal.{cls}: {hasattr(unreal, cls)}")

# AnimPoseExtensions surface
ape = [m for m in dir(unreal.AnimPoseExtensions) if not m.startswith("_")]
unreal.log(f"[probe] AnimPoseExtensions: {ape}")

# try the 1-arg reference pose form on our SK
sk = unreal.EditorAssetLibrary.load_asset("/MolotovBottle/SK_MolotovBottle")
if sk:
    try:
        pose = unreal.AnimPoseExtensions.get_reference_pose(sk)
        unreal.log(f"[probe] get_reference_pose(sk) -> {type(pose).__name__}")
        try:
            names = [str(n) for n in unreal.AnimPoseExtensions.get_bone_names(pose)]
            unreal.log(f"[probe] bones: {names}")
            t = unreal.AnimPoseExtensions.get_bone_pose(
                pose, "jnt_fuse", unreal.AnimPoseSpaces.WORLD
            )
            unreal.log(f"[probe] jnt_fuse world: {t.translation}")
            t2 = unreal.AnimPoseExtensions.get_bone_pose(
                pose, "jnt_offset", unreal.AnimPoseSpaces.WORLD
            )
            unreal.log(f"[probe] jnt_offset world: {t2.translation}")
        except Exception as e:
            unreal.log(f"[probe] bone pose: {e}")
    except Exception as e:
        unreal.log(f"[probe] get_reference_pose: {e}")

# if bodies are reachable, dump one body's surface too
try:
    arr = pa.get_editor_property("skeletal_body_setups")
    if len(arr):
        b = arr[0]
        unreal.log(f"[probe] body dir: {[m for m in dir(b) if not m.startswith('_')]}")
except Exception:
    pass

unreal.log("PROBE_DONE")
