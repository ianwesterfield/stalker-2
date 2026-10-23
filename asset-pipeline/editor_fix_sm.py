# Fix SM_MolotovBottle after import: droop-friendly build settings, assign all
# 4 material slots by name, add simple collision, SAVE TO DISK, audit slots.
# Run in editor Output Log:  py "<this file>"
import unreal

PLUGIN = "/MolotovBottle"
SM_PATH = f"{PLUGIN}/SM_MolotovBottle"
GAME_MATS = "/Game/_Stalker_2/items/consumable/Materials"
ASSIGN = {
    "MI_cns_cossacks_vodka_01_glass": f"{GAME_MATS}/MI_cns_cossacks_vodka_01_glass",
    "MI_cns_cossacks_vodka_01_02": f"{GAME_MATS}/MI_cns_cossacks_vodka_01_02",
    "MI_molotov_rag": f"{PLUGIN}/M_MolotovRag",
    "M_RagFlame": f"{PLUGIN}/M_RagFlame",
}

sm = unreal.EditorAssetLibrary.load_asset(SM_PATH)
assert sm, "SM_MolotovBottle missing - run editor_import_sm.py first"

nanite_settings = sm.get_editor_property("nanite_settings")
unreal.log(f"[fixsm] Nanite before: {nanite_settings.get_editor_property('enabled')}")
nanite_settings.set_editor_property("enabled", False)
sm.set_editor_property("nanite_settings", nanite_settings)
assert not sm.get_editor_property("nanite_settings").get_editor_property("enabled")
unreal.log("[fixsm] Nanite disabled for static bottle render test")

sub = unreal.get_editor_subsystem(unreal.StaticMeshEditorSubsystem)
bs = sub.get_lod_build_settings(sm, 0)
bs.set_editor_property("recompute_normals", False)
bs.set_editor_property("recompute_tangents", True)
bs.set_editor_property("use_mikk_t_space", True)
sub.set_lod_build_settings(sm, 0, bs)
unreal.log("[fixsm] build settings: keep normals, MikkTSpace tangents")

mats = sm.get_editor_property("static_materials")
for i, entry in enumerate(mats):
    slot = str(entry.get_editor_property("material_slot_name"))
    tgt = ASSIGN.get(slot)
    if tgt:
        mat = unreal.EditorAssetLibrary.load_asset(tgt)
        assert mat, f"missing material {tgt}"
        sm.set_material(i, mat)
    else:
        unreal.log_warning(f"[fixsm] unmapped slot name '{slot}'")
    cur = sm.get_material(i)
    unreal.log(
        f"[fixsm] final slot {i} ({slot}): " f"{cur.get_path_name() if cur else 'NULL'}"
    )

shape_enum = getattr(unreal, "ScriptingCollisionShapeType", None) or getattr(
    unreal, "ScriptCollisionShapeType", None
)
try:
    if sub.get_simple_collision_count(sm) == 0 and shape_enum:
        added = sub.add_simple_collisions(sm, shape_enum.BOX)
        unreal.log(f"[fixsm] added box collision: {added}")
    else:
        unreal.log(
            f"[fixsm] simple collision count: {sub.get_simple_collision_count(sm)}"
        )
except Exception as e:
    unreal.log_warning(f"[fixsm] collision step failed (non-fatal): {e}")

saved = unreal.EditorAssetLibrary.save_asset(SM_PATH, only_if_is_dirty=False)
unreal.log(f"[fixsm] SM_FIXED saved={saved}")
