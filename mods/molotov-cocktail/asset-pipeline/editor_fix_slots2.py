# Reassign SK_MolotovBottle material slots after a scripted reimport and drop
# trailing slots no section uses. Run:  py "<this file>"
import unreal

PLUGIN = "/MolotovBottle"
GAME_MATS = "/Game/_Stalker_2/items/consumable/Materials"
ASSIGN = {
    "MI_cns_cossacks_vodka_01_glass": f"{GAME_MATS}/MI_cns_cossacks_vodka_01_glass",
    "MI_cns_cossacks_vodka_01_02": f"{GAME_MATS}/MI_cns_cossacks_vodka_01_02",
    "MI_molotov_rag": f"{PLUGIN}/M_MolotovRag",
}

sk = unreal.EditorAssetLibrary.load_asset(f"{PLUGIN}/SK_MolotovBottle")
mats = list(sk.get_editor_property("materials"))
seen = set()
for i, sm in enumerate(mats):
    slot = str(sm.get_editor_property("material_slot_name"))
    seen.add(slot)
    cur = sm.get_editor_property("material_interface")
    want = ASSIGN.get(slot)
    if want and (cur is None or cur.get_path_name().split(".")[0] != want):
        m = unreal.EditorAssetLibrary.load_asset(want)
        if not m:
            unreal.log_warning(f"slot {i} '{slot}': {want} NOT FOUND")
            continue
        mats[i] = unreal.SkeletalMaterial(
            material_interface=m,
            material_slot_name=sm.get_editor_property("material_slot_name"),
        )
        unreal.log(f"slot {i} '{slot}' -> {want}")
    else:
        unreal.log(f"slot {i} '{slot}' OK")

missing = set(ASSIGN) - seen
assert not missing, f"import dropped slots {sorted(missing)}"

# reimport can keep slots the FBX no longer has; they trail the live ones
while mats and str(mats[-1].get_editor_property("material_slot_name")) not in ASSIGN:
    unreal.log(f"DROPPED stale slot '{mats[-1].get_editor_property('material_slot_name')}'")
    mats.pop()

assert len(mats) == len(ASSIGN), f"unexpected slots {[str(m.get_editor_property('material_slot_name')) for m in mats]}"

sk.set_editor_property("materials", mats)
# set_editor_property only dirties the package — must save or cook sees stale slots
saved = unreal.EditorAssetLibrary.save_asset(
    f"{PLUGIN}/SK_MolotovBottle", only_if_is_dirty=False
)
for i, sm in enumerate(sk.get_editor_property("materials")):
    mi = sm.get_editor_property("material_interface")
    unreal.log(f"final slot {i}: {mi.get_path_name() if mi else 'NULL'}")
unreal.log(f"SLOTS_FIXED saved={saved}")
