# Dump SK_MolotovBottle slots + find the vodka materials in the asset registry.
# Run:  py "<this file>"
import unreal

sk = unreal.EditorAssetLibrary.load_asset("/MolotovBottle/SK_MolotovBottle")
mats = sk.get_editor_property("materials")
unreal.log(f"DUMP slot count: {len(mats)}")
for i, sm in enumerate(mats):
    cur = sm.get_editor_property("material_interface")
    unreal.log(
        f"DUMP slot {i}: name='{sm.get_editor_property('material_slot_name')}' "
        f"mat={cur.get_path_name() if cur else None}"
    )

ar = unreal.AssetRegistryHelpers.get_asset_registry()
f = unreal.ARFilter(
    class_paths=[
        unreal.TopLevelAssetPath("/Script/Engine", "MaterialInstanceConstant")
    ],
    package_paths=["/Game"],
    recursive_paths=True,
)
hits = [a for a in ar.get_assets(f) if "cossacks_vodka" in str(a.package_name)]
for a in hits:
    unreal.log(f"DUMP found: {a.package_name}")
unreal.log("DUMP_DONE")
