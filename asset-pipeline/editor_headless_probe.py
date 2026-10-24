# Headless probe: verify the Zone Kit Shipping editor exposes the Python
# commandlet and the Interchange wait API needed for synchronous imports.
# Run: Stalker2ModEditor-Win64-Shipping-Cmd.exe <uproject> -run=pythonscript -script="<this file>"
import unreal

unreal.log(f"PROBE engine={unreal.SystemLibrary.get_engine_version()}")
mgr = unreal.InterchangeManager.get_interchange_manager_scripted()
unreal.log(f"PROBE interchange_mgr={mgr is not None}")
unreal.log(
    f"PROBE wait_api={hasattr(unreal.InterchangeManager, 'wait_until_all_tasks_done')}"
)
sk = unreal.EditorAssetLibrary.load_asset("/MolotovBottle/SK_MolotovBottle")
unreal.log(f"PROBE plugin_asset_loaded={sk is not None}")
unreal.log("PYTHONSCRIPT_PROBE_OK")
