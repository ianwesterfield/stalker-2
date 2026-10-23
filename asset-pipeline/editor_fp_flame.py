"""Flame-only FOV fix: place MF_Foreground_FOVCorrection fed by MPC_FOV TanFOV
(the correct vanilla source) plus an Add to merge with the animated WPO chain.
Skips AntiDepthClipping/ShadowSwitch entirely (streak suspects; flame writes no
depth so it only needs the positional correction).

Hand-wire after running: Add_7 (final bend+sway/droop+flutter combine) -> new
Add 'A', new Add output -> World Position Offset pin. Script wires the rest.

Run in Zone Kit Output Log (Cmd):
  py "C:\\Code\\westerfield.cloud\\Gaming\\stalker-2\\asset-pipeline\\editor_fp_flame.py"
"""

import unreal

MAT_PATH = "/MolotovBottle/M_RagFlame"
MF_PATH = (
    "/Game/_Stalker_2/Materials/MaterialFunctions/Foreground/"
    "MF_Foreground_FOVCorrection"
)
MPC_PATH = "/Game/_Stalker_2/Materials/MPC/MPC_FOV"

MEL = unreal.MaterialEditingLibrary
mf = unreal.EditorAssetLibrary.load_asset(MF_PATH)
mpc = unreal.EditorAssetLibrary.load_asset(MPC_PATH)
mat = unreal.EditorAssetLibrary.load_asset(MAT_PATH)
assert mf and mpc and mat

call = MEL.create_material_expression(
    mat, unreal.MaterialExpressionMaterialFunctionCall, -600, 900
)
call.set_editor_property("material_function", mf)
call.set_editor_property(
    "desc", "FOV CORE ONLY: out -> Add.B; Add_7 -> Add.A; Add -> WPO pin"
)

tan_fov = MEL.create_material_expression(
    mat, unreal.MaterialExpressionCollectionParameter, -850, 900
)
tan_fov.set_editor_property("collection", mpc)
tan_fov.set_editor_property("parameter_name", "TanFOV")

add = MEL.create_material_expression(mat, unreal.MaterialExpressionAdd, -350, 850)
add.set_editor_property("desc", "WPO FINAL: chain + FOV correction")

ok1 = MEL.connect_material_expressions(tan_fov, "", call, "Foreground FOV")
ok2 = MEL.connect_material_expressions(call, "", add, "B")
unreal.log(f"[fpflame] TanFOV->MF ok={ok1}, MF->Add.B ok={ok2}")

MEL.recompile_material(mat)
saved = unreal.EditorAssetLibrary.save_asset(MAT_PATH, only_if_is_dirty=False)
unreal.log(
    f"[fpflame] saved={saved} - HAND-WIRE: Add_7 (old chain final Add, "
    "currently on WPO pin) -> new Add 'A'; new Add output -> WPO pin; save"
)
