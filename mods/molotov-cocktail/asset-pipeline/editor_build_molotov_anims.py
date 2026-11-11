# Give the molotov its own throw animations so it stops pulling a pin that
# isn't there. Chain being rebuilt (vanilla assets are never touched, so real
# RGD-5s keep their pin):
#
#   GrenadeMolotov.cfg GrenadeAnimBlueprint
#     -> /MolotovBottle/AnimBP_Molotov_fp   (dup of AnimBP_Rgd5_fp)
#        .weapon_anim_collection
#     -> /MolotovBottle/AnimCollection_fp_Molotov  (dup of AninCollection_fp_Rgd5)
#        .weapon_animations.player_anim_blueprint
#     -> AnimBP_Player_fp_bolt  (the bolt throws with no pin, and has the
#                                lefthand/one-handed variants we need)
import unreal

EAL = unreal.EditorAssetLibrary
PLUGIN = "/MolotovBottle"

SRC_COLL = (
    "/Game/_STALKER2/Animations/Weapons/grenades/RGD5/AnimCollections/"
    "AninCollection_fp_Rgd5"  # GSC's typo, not ours
)
SRC_BP = "/Game/_STALKER2/Animations/Weapons/grenades/RGD5/AnimBP_Rgd5_fp"
BOLT_PLAYER_BP = "/Game/_STALKER2/Animations/Weapons/bolt/AnimBP_Player_fp_bolt"

DST_COLL = f"{PLUGIN}/AnimCollection_fp_Molotov"
DST_BP = f"{PLUGIN}/AnimBP_Molotov_fp"

unreal.AssetRegistryHelpers.get_asset_registry().scan_paths_synchronous(
    [PLUGIN], force_rescan=True
)


def fresh_copy(src, dst):
    if EAL.does_asset_exist(dst):
        EAL.delete_asset(dst)
    assert EAL.duplicate_asset(src, dst), f"duplicate failed: {src} -> {dst}"
    asset = EAL.load_asset(dst)
    assert asset, f"could not load duplicate: {dst}"
    return asset


# 1. our collection, pointed at the bolt's pin-free player animations
coll = fresh_copy(SRC_COLL, DST_COLL)
bolt_bp = EAL.load_asset(BOLT_PLAYER_BP)
assert bolt_bp, f"missing bolt anim bp: {BOLT_PLAYER_BP}"
bolt_class = bolt_bp.generated_class()
assert bolt_class, "bolt anim bp has no generated class"

weapon_anims = coll.get_editor_property("weapon_animations")
before = weapon_anims.get_editor_property("player_anim_blueprint")
weapon_anims.set_editor_property("player_anim_blueprint", bolt_class)
coll.set_editor_property("weapon_animations", weapon_anims)
unreal.log(f"MOLOTOVANIM collection player_anim_blueprint {before} -> {bolt_class}")
assert EAL.save_asset(DST_COLL), f"save failed: {DST_COLL}"

# 2. our anim blueprint, pointed at our collection
bp = fresh_copy(SRC_BP, DST_BP)
gen = bp.generated_class()
assert gen, "duplicated anim bp has no generated class"
cdo = unreal.get_default_object(gen)
assert cdo, "no CDO on duplicated anim bp"
cdo.set_editor_property("weapon_anim_collection", coll)
try:
    unreal.BlueprintEditorLibrary.compile_blueprint(bp)
except Exception as exc:  # CDO edits can need a recompile to stick through cook
    unreal.log_warning(f"MOLOTOVANIM compile skipped: {exc}")
assert EAL.save_asset(DST_BP), f"save failed: {DST_BP}"

# read back from a fresh load - a silent revert here would ship a pin-pulling bottle
check_coll = EAL.load_asset(DST_COLL)
check_bp = EAL.load_asset(DST_BP)
final_player = check_coll.get_editor_property("weapon_animations").get_editor_property(
    "player_anim_blueprint"
)
final_coll = unreal.get_default_object(check_bp.generated_class()).get_editor_property(
    "weapon_anim_collection"
)
unreal.log(f"MOLOTOVANIM verify player_anim_blueprint={final_player}")
unreal.log(f"MOLOTOVANIM verify weapon_anim_collection={final_coll}")
unreal.log("MOLOTOVANIM_DONE")
