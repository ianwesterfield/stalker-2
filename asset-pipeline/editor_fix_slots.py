# Reassign SK_MolotovBottle material slots after a scripted reimport (the
# explicit Interchange pipeline skips GSC's slot cache). Run:  py "<this file>"
import unreal

PLUGIN = "/MolotovBottle"
ASSIGN = {
    "MI_molotov_rag": f"{PLUGIN}/M_MolotovRag",
    "M_RagFlame": f"{PLUGIN}/M_RagFlame",
    "MI_cns_cossacks_vodka_01_glass": "/Game/_STALKER2/Materials/consumables/MI_cns_cossacks_vodka_01_glass",
    "MI_cns_cossacks_vodka_01_02": "/Game/_STALKER2/Materials/consumables/MI_cns_cossacks_vodka_01_02",
}

sk = unreal.EditorAssetLibrary.load_asset(f"{PLUGIN}/SK_MolotovBottle")
mats = list(sk.get_editor_property("materials"))
for i, sm in enumerate(mats):
    slot = str(sm.get_editor_property("material_slot_name"))
    cur = sm.get_editor_property("material_interface")
    want = ASSIGN.get(slot)
    if want and (cur is None or cur.get_path_name().split(".")[0] != want):
        m = unreal.EditorAssetLibrary.load_asset(want)
        if not m:
            unreal.log_warning(f"slot {i} '{slot}': {want} NOT FOUND — assign by hand")
            continue
        mats[i] = unreal.SkeletalMaterial(
            material_interface=m,
            material_slot_name=sm.get_editor_property("material_slot_name"),
        )
        unreal.log(f"slot {i} '{slot}' -> {want}")
    else:
        unreal.log(f"slot {i} '{slot}' OK ({cur.get_path_name() if cur else None})")
sk.set_editor_property("materials", mats)
unreal.log("SLOTS_FIXED")
