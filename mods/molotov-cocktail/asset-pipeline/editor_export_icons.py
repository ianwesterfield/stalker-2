# Export the vanilla vodka bottle texture to PNG so the icon render can use the
# real artwork. It only exists as a cooked asset in the game paks, so the
# editor is the only thing that can hand it over as an image.
# Run standalone (no plugin junction needed — it's a /Game asset):
#   Stalker2ModEditor-Win64-Shipping-Cmd.exe <uproject> -run=pythonscript -script="<this>"
import os

import unreal

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "out", "vanilla")
TEXTURES = "/Game/_Stalker_2/items/consumable/Textures"
WANTED = {
    "T_cns_cossacks_vodka_01_02_D": f"{TEXTURES}/T_cns_cossacks_vodka_01_02_D",
}

os.makedirs(OUT, exist_ok=True)
unreal.AssetRegistryHelpers.get_asset_registry().scan_paths_synchronous(
    [TEXTURES], force_rescan=True
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
