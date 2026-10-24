# Headless editor driver: runs the import+fix scripts in ONE editor boot via
#   Stalker2ModEditor-Win64-Shipping-Cmd.exe <uproject> -run=pythonscript -script="<this>"
# Requires the plugin junctioned into Stalker2\Plugins (pipeline.ps1 does it).
# In -unattended commandlet mode Interchange imports complete SYNCHRONOUSLY,
# so each step sees the previous one's result. Exit code is unreliable (boot
# noise like S2_DLC1 logs errors) — callers must gate on HEADLESS_ALL_DONE.
import os

import unreal

HERE = os.path.dirname(os.path.abspath(__file__))
STEPS = (
    "editor_reimport_sk.py",
    "editor_fix_slots2.py",
    "editor_fix_phys.py",
    "editor_import_sm.py",
    "editor_fix_sm.py",
)

# commandlets skip the full asset registry scan — plugin content is invisible
# to load_asset until we force one
unreal.AssetRegistryHelpers.get_asset_registry().scan_paths_synchronous(
    ["/MolotovBottle"], force_rescan=True
)
assert unreal.EditorAssetLibrary.does_directory_exist("/MolotovBottle/"), (
    "plugin not mounted — run through pipeline.ps1 (junctions Mods\\MolotovBottle "
    "into Stalker2\\Plugins)"
)

for name in STEPS:
    path = os.path.join(HERE, name)
    unreal.log(f"HEADLESS_STEP {name}")
    with open(path, encoding="utf-8") as f:
        code = compile(f.read(), path, "exec")
    exec(code, {"__name__": "__main__", "__file__": path})

unreal.log("HEADLESS_ALL_DONE")
