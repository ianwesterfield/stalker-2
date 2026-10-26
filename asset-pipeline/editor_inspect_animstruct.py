# Read the throwable collections' animation structs. Option A hinges on these
# being readable AND settable on a duplicate: if we can swap the RGD5 throw
# montages for the bolt's pin-free ones, the molotov keeps its own collection
# and real RGD-5s are untouched. Read-only.
import unreal

TARGETS = {
    "RGD5": "/Game/_STALKER2/Animations/Weapons/grenades/RGD5/AnimCollections/AninCollection_fp_Rgd5",
    "BOLT": "/Game/_STALKER2/Animations/Weapons/bolt/AnimCollections/AnimCollection_fp_bolt",
}
FIELDS = (
    "internal_animations",
    "weapon_animations",
    "external_animations",
    "parent_anim_collection",
)


def describe(tag, label, value, depth=0):
    pad = "  " * depth
    if value is None:
        unreal.log(f"ANIMSTRUCT {tag} {pad}{label} = None")
        return
    if isinstance(value, unreal.Object):
        unreal.log(f"ANIMSTRUCT {tag} {pad}{label} -> {value.get_path_name()}")
        return
    if isinstance(value, unreal.StructBase):
        unreal.log(f"ANIMSTRUCT {tag} {pad}{label} (struct)")
        if depth >= 2:
            return
        for name in sorted(dir(value)):
            if name.startswith("_"):
                continue
            try:
                inner = getattr(value, name)
            except Exception:
                continue
            if callable(inner):
                continue
            describe(tag, name, inner, depth + 1)
        return
    text = str(value)
    unreal.log(f"ANIMSTRUCT {tag} {pad}{label} = {text[:200]}")


for tag, path in TARGETS.items():
    asset = unreal.EditorAssetLibrary.load_asset(path)
    if not asset:
        unreal.log_warning(f"ANIMSTRUCT {tag} MISSING")
        continue
    unreal.log(f"ANIMSTRUCT {tag} {path}")
    for field in FIELDS:
        try:
            describe(tag, field, asset.get_editor_property(field))
        except Exception as exc:
            unreal.log(f"ANIMSTRUCT {tag} {field} unreadable: {exc}")

unreal.log("ANIMSTRUCT_DONE")
