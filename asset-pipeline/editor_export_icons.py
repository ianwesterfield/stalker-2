# Export vanilla icon/label textures to PNG so the icon build can use the real
# artwork. The textures only exist as cooked assets in the game paks, so the
# editor is the only thing that can hand them over as images.
# Run standalone (no plugin junction needed — these are all /Game assets):
#   Stalker2ModEditor-Win64-Shipping-Cmd.exe <uproject> -run=pythonscript -script="<this>"
import os

import unreal

OUT = r"c:\Code\westerfield.cloud\Gaming\stalker-2\asset-pipeline\out\vanilla"
UI = "/Game/GameLite/FPS_Game/UIRemaster/UITextures/Inventory/Consumable"
WANTED = {
    "T_cns_cossacks_vodka_01": f"{UI}/T_cns_cossacks_vodka_01",
    "T_cns_bandage_01": f"{UI}/T_cns_bandage_01",
    "T_cns_cossacks_vodka_01_02_D": (
        "/Game/_Stalker_2/items/consumable/Textures/" "T_cns_cossacks_vodka_01_02_D"
    ),
}

os.makedirs(OUT, exist_ok=True)
unreal.AssetRegistryHelpers.get_asset_registry().scan_paths_synchronous(
    [UI, "/Game/_Stalker_2/items/consumable/Textures"], force_rescan=True
)

for name, path in WANTED.items():
    tex = unreal.EditorAssetLibrary.load_asset(path)
    if not tex:
        unreal.log_warning(f"ICON_EXPORT missing {path}")
        continue
    task = unreal.AssetExportTask()
    task.set_editor_property("object", tex)
    task.set_editor_property("filename", os.path.join(OUT, name + ".png"))
    task.set_editor_property("automated", True)
    task.set_editor_property("prompt", False)
    task.set_editor_property("replace_identical", True)
    ok = unreal.Exporter.run_asset_export_task(task)
    unreal.log(f"ICON_EXPORT {name} ok={ok}")

unreal.log("ICON_EXPORT_DONE " + ";".join(sorted(os.listdir(OUT))))
