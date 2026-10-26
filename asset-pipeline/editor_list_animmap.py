# Find the data assets that map a throwable to its montages. If the molotov's
# throw montages are chosen by a collection asset we can ship our own and point
# it at pin-free motions; if they are hard-wired in an AnimBP, they are not
# reachable from a cfg mod. Read-only.
import unreal

AR = unreal.AssetRegistryHelpers.get_asset_registry()

CLASSES = (
    "PlayerThrowableItemAnimCollection",
    "ItemAnimCollection",
    "AnimCollection",
)
for cls in CLASSES:
    try:
        found = AR.get_assets_by_class(
            unreal.TopLevelAssetPath("/Script/Stalker2", cls), search_sub_classes=True
        )
    except Exception as exc:
        unreal.log_warning(f"ANIMMAP class {cls} query failed: {exc}")
        continue
    unreal.log(f"ANIMMAP class={cls} count={len(found)}")
    for a in found:
        unreal.log(f"ANIMMAP   {a.package_name}")

# the RGD5 anim blueprint the molotov inherits from its refkey parent
for path in (
    "/Game/_STALKER2/Animations/Weapons/grenades/RGD5/AnimBP_Rgd5_fp",
    "/Game/_STALKER2/Animations/Weapons/grenades/RGD5",
):
    exists = unreal.EditorAssetLibrary.does_asset_exist(path)
    unreal.log(f"ANIMMAP exists {path} = {exists}")

AR.scan_paths_synchronous(["/Game/_STALKER2/Animations/Weapons/grenades/RGD5"], True)
for a in AR.get_assets_by_path(
    "/Game/_STALKER2/Animations/Weapons/grenades/RGD5", recursive=True
):
    unreal.log(f"ANIMMAP rgd5 {a.asset_class_path.asset_name} {a.package_name}")

unreal.log("ANIMMAP_DONE")
