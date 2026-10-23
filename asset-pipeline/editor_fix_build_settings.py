# Fix SK_MolotovBottle LOD0 build settings: stop recomputing normals (kills
# the flame-axis normal hijack). Tangents stay recomputed (MikkTSpace from
# UVs) — the rag droop axis needs valid tangents and the FBX carries none.
# Run in the editor Output Log:  py "<this file>"
import unreal

sk_path = "/MolotovBottle/SK_MolotovBottle"
sk = unreal.EditorAssetLibrary.load_asset(sk_path)
assert sk, "SK_MolotovBottle missing"

subsys = unreal.get_editor_subsystem(unreal.SkeletalMeshEditorSubsystem)
bs = subsys.get_lod_build_settings(sk, 0)
unreal.log(
    f"BEFORE recompute_normals={bs.recompute_normals} "
    f"recompute_tangents={bs.recompute_tangents} "
    f"mikk={bs.use_mikk_t_space}"
)

bs.recompute_normals = False
bs.recompute_tangents = True
bs.use_mikk_t_space = True
subsys.set_lod_build_settings(sk, 0, bs)

bs2 = subsys.get_lod_build_settings(sk, 0)
unreal.log(
    f"AFTER  recompute_normals={bs2.recompute_normals} "
    f"recompute_tangents={bs2.recompute_tangents} "
    f"mikk={bs2.use_mikk_t_space}"
)

unreal.EditorAssetLibrary.save_asset(sk_path)
unreal.log("BUILD_SETTINGS_FIXED")
