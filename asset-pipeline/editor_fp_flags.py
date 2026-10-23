"""Copy missing material usage flags (esp. first-person) from the vanilla
bottle's base material onto our plugin materials, then save.

Run in Zone Kit Output Log:  py "<path>\editor_fp_flags.py"
"""

import unreal

PLUGIN = "/MolotovBottle"
VANILLA_MI = (
    "/Game/_Stalker_2/items/consumable/Materials/MI_cns_cossacks_vodka_01_glass"
)
OURS = ["M_MolotovRag", "M_RagFlame"]


def base_material(asset):
    while isinstance(asset, unreal.MaterialInstance):
        asset = asset.get_editor_property("parent")
    return asset


def flag_names(mat):
    names = set()
    for n in dir(mat):
        low = n.lower()
        if low.startswith("used_with") or "first_person" in low:
            try:
                if isinstance(mat.get_editor_property(n), bool):
                    names.add(n)
            except Exception:
                pass
    return names


mi = unreal.EditorAssetLibrary.load_asset(VANILLA_MI)
vbase = base_material(mi)
unreal.log(f"[fpflags] vanilla base = {vbase.get_path_name()}")

vflags = {n: vbase.get_editor_property(n) for n in flag_names(vbase)}
for n in sorted(vflags):
    unreal.log(f"[fpflags] vanilla {n} = {vflags[n]}")

for name in OURS:
    mat = unreal.EditorAssetLibrary.load_asset(f"{PLUGIN}/{name}")
    changed = []
    for n, v in vflags.items():
        if not v:
            continue
        try:
            cur = mat.get_editor_property(n)
        except Exception:
            unreal.log_warning(f"[fpflags] {name}: no property {n}")
            continue
        if not cur:
            mat.set_editor_property(n, True)
            changed.append(n)
    saved = unreal.EditorAssetLibrary.save_asset(
        f"{PLUGIN}/{name}", only_if_is_dirty=False
    )
    unreal.log(f"[fpflags] {name}: set {changed or 'nothing'} saved={saved}")

unreal.log("[fpflags] DONE")
