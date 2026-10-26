# Find what selects a throwable's anim collection. The collection points at the
# player AnimBP (readable), but the item cfg only names GrenadeAnimBlueprint, so
# something in between picks the collection. Read-only.
#
# Every probe is guarded: an unhandled exception kills the commandlet and you
# lose the rest of the run's output.
import unreal

ANIMBP = "/Game/_STALKER2/Animations/Weapons/grenades/RGD5/AnimBP_Rgd5_fp"
COLLECTION = (
    "/Game/_STALKER2/Animations/Weapons/grenades/RGD5/AnimCollections/"
    "AninCollection_fp_Rgd5"
)


def safe(label, fn):
    try:
        return fn()
    except Exception as exc:
        unreal.log(f"BPPROBE {label} failed: {exc}")
        return None


bp = safe("load animbp", lambda: unreal.EditorAssetLibrary.load_asset(ANIMBP))
unreal.log(f"BPPROBE animbp loaded={bp is not None}")

if bp:
    for attr in ("generated_class", "target_skeleton", "parent_class"):
        unreal.log(
            f"BPPROBE {attr} = {safe(attr, lambda a=attr: bp.get_editor_property(a))}"
        )

    gen = safe("gen", lambda: bp.generated_class())
    unreal.log(f"BPPROBE generated_class() = {gen}")
    cdo = safe("cdo", lambda: unreal.get_default_object(gen)) if gen else None
    if cdo:
        for name in sorted(dir(cdo)):
            if name.startswith("_"):
                continue
            v = safe(name, lambda n=name: getattr(cdo, n))
            if v is None or callable(v):
                continue
            text = str(v)
            if "ollection" in text or "ollection" in name:
                unreal.log(f"BPPROBE   cdo.{name} = {text[:200]}")

# whoever references the collection owns the link
refs = safe(
    "referencers",
    lambda: unreal.AssetRegistryHelpers.get_asset_registry().get_referencers(
        unreal.Name(COLLECTION), unreal.AssetRegistryDependencyOptions()
    ),
)
unreal.log(f"BPPROBE referencers={len(refs) if refs else 0}")
for r in refs or []:
    unreal.log(f"BPPROBE   ref {r}")

unreal.log("BPPROBE_DONE")
