"""One-boot probe: is FPhysAssetCreateParams exposed, and does
create_physics_asset take params? Prints [probe2] lines."""

import unreal

for cls in ("PhysAssetCreateParams", "PhysicsAssetUtils", "PhysicsAssetEditorOptions"):
    c = getattr(unreal, cls, None)
    unreal.log(f"[probe2] unreal.{cls} = {c}")
    if c:
        try:
            inst = c()
            props = [p for p in dir(inst) if not p.startswith("_")]
            unreal.log(f"[probe2] {cls} dir: {props}")
        except Exception as e:
            unreal.log(f"[probe2] {cls} instantiate FAIL: {e}")

sub = unreal.get_editor_subsystem(unreal.SkeletalMeshEditorSubsystem)
import inspect

try:
    unreal.log(f"[probe2] create_physics_asset doc: {sub.create_physics_asset.__doc__}")
except Exception as e:
    unreal.log(f"[probe2] doc FAIL: {e}")

# also probe the modeling/physics scripted helpers that sometimes carry params
for name in dir(unreal):
    if "phys" in name.lower() and (
        "library" in name.lower()
        or "subsystem" in name.lower()
        or "util" in name.lower()
    ):
        unreal.log(f"[probe2] candidate: {name}")

unreal.log("PROBE2_DONE")
