"""Add GSC's MF_Foreground_FOVCorrection into the WPO chain of our plugin
materials so they warp with the first-person viewmodel like vanilla ones.

The WPO property pin and MF pin lists are unreachable from Python in this
build, so this places the nodes and wires what it can; the final hop into
the WPO pin is hand-wired in the GUI (same as every mat rebuild).

Run in Zone Kit Output Log (Cmd):
  py "C:\\Code\\westerfield.cloud\\Gaming\\stalker-2\\asset-pipeline\\editor_fp_patch.py"
"""

import unreal

PLUGIN = "/MolotovBottle"
OURS = ["M_MolotovRag", "M_RagFlame"]
MF_PATH = "/Game/_Stalker_2/Materials/MaterialFunctions/Foreground/MF_Foreground_FOVCorrection"

MEL = unreal.MaterialEditingLibrary

mf = unreal.EditorAssetLibrary.load_asset(MF_PATH)

for name in OURS:
    path = f"{PLUGIN}/{name}"
    mat = unreal.EditorAssetLibrary.load_asset(path)

    call = MEL.create_material_expression(
        mat, unreal.MaterialExpressionMaterialFunctionCall, -900, 600
    )
    call.set_editor_property("material_function", mf)
    try:
        call.update_from_function_resource()
    except Exception as e:
        unreal.log(f"[fppatch] {name}: update_from_function_resource: {e}")

    # helper in case the MF exposes a position input (wire by hand if so)
    wp = MEL.create_material_expression(
        mat, unreal.MaterialExpressionWorldPosition, -1150, 700
    )

    add = MEL.create_material_expression(mat, unreal.MaterialExpressionAdd, -600, 500)
    add.set_editor_property("desc", "FOV ADD: old WPO source -> A, output -> WPO pin")
    ok_b = MEL.connect_material_expressions(call, "", add, "B")
    unreal.log(f"[fppatch] {name}: MFCall -> 'FOV ADD'.B ok={ok_b}")

    MEL.recompile_material(mat)
    saved = unreal.EditorAssetLibrary.save_asset(path, only_if_is_dirty=False)
    unreal.log(f"[fppatch] {name}: nodes placed, saved={saved}")

unreal.log(
    "[fppatch] DONE — hand-wire in each material: old WPO source -> 'FOV ADD'.A, "
    "'FOV ADD' output -> WPO pin; if the MF node shows an empty position-like "
    "input, wire the WorldPosition node into it; then save both materials"
)
