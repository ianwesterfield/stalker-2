# Dump the throwable anim collections so we can see which fields hold the
# pin-pull montages before duplicating anything. Read-only.
import unreal

TARGETS = {
    "RGD5": "/Game/_STALKER2/Animations/Weapons/grenades/RGD5/AnimCollections/AninCollection_fp_Rgd5",
    "BOLT": "/Game/_STALKER2/Animations/Weapons/bolt/AnimCollections/AnimCollection_fp_bolt",
}


def dump(tag, path):
    asset = unreal.EditorAssetLibrary.load_asset(path)
    if not asset:
        unreal.log_warning(f"ANIMPROP {tag} MISSING {path}")
        return
    unreal.log(f"ANIMPROP {tag} class={asset.get_class().get_name()}")
    for name in sorted(dir(asset)):
        if name.startswith("_"):
            continue
        try:
            value = getattr(asset, name)
        except Exception:
            continue
        if callable(value):
            continue
        text = str(value)
        if len(text) > 240:
            text = text[:240] + "..."
        unreal.log(f"ANIMPROP {tag}   {name} = {text}")


for tag, path in TARGETS.items():
    dump(tag, path)

unreal.log("ANIMPROP_DONE")
