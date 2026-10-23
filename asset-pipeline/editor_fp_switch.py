"""Replace our always-on MF_Foreground_FOVCorrection chain with vanilla's exact
Custom FOV block (from M_PBR_Glass_Emissive): MF_ForegroundWithShadowSwitch fed
by MPC_FOV TanFOV/DepthScale + ForegroundFOVEnabled scalar param (default 0,
runtime flips it on FP material instances).

Places + wires what Python can reach; hand-wire the two unreachable hops:
  1. old final WPO Add output -> MF 'Base World Position Offset (V3)' input
  2. MF 'WPO' output -> material World Position Offset pin
then DELETE the old FOV node, MF_Foreground_FOVCorrection call, and 'FOV ADD'.

Run in Zone Kit Output Log (Cmd):
  py "C:\\Code\\westerfield.cloud\\Gaming\\stalker-2\\asset-pipeline\\editor_fp_switch.py"
"""

import unreal

PLUGIN = "/MolotovBottle"
OURS = ["M_MolotovRag", "M_RagFlame"]
MF_PATH = (
    "/Game/_Stalker_2/Materials/MaterialFunctions/Foreground/"
    "MF_ForegroundWithShadowSwitch"
)
MPC_PATH = "/Game/_Stalker_2/Materials/MPC/MPC_FOV"

MEL = unreal.MaterialEditingLibrary

mf = unreal.EditorAssetLibrary.load_asset(MF_PATH)
mpc = unreal.EditorAssetLibrary.load_asset(MPC_PATH)
assert mf and mpc, "vanilla MF/MPC assets missing"


def try_connect(src, src_pin, dst, pin_candidates, label):
    for pin in pin_candidates:
        if MEL.connect_material_expressions(src, src_pin, dst, pin):
            unreal.log(f"[fpswitch]   {label} -> '{pin}' OK")
            return True
    unreal.log_warning(
        f"[fpswitch]   {label}: no pin matched {pin_candidates} - wire by hand"
    )
    return False


for name in OURS:
    path = f"{PLUGIN}/{name}"
    mat = unreal.EditorAssetLibrary.load_asset(path)
    unreal.log(f"[fpswitch] {name}:")

    call = MEL.create_material_expression(
        mat, unreal.MaterialExpressionMaterialFunctionCall, -500, 900
    )
    call.set_editor_property("material_function", mf)
    try:
        call.update_from_function_resource()
    except Exception as e:
        unreal.log(f"[fpswitch]   update_from_function_resource: {e}")
    call.set_editor_property(
        "desc",
        "VANILLA FOV SWITCH: old WPO Add -> Base WPO (V3), WPO out -> WPO pin; "
        "then delete old FOV node + FOVCorrection call + FOV ADD",
    )

    tan_fov = MEL.create_material_expression(
        mat, unreal.MaterialExpressionCollectionParameter, -850, 850
    )
    tan_fov.set_editor_property("collection", mpc)
    tan_fov.set_editor_property("parameter_name", "TanFOV")

    depth_scale = MEL.create_material_expression(
        mat, unreal.MaterialExpressionCollectionParameter, -850, 950
    )
    depth_scale.set_editor_property("collection", mpc)
    depth_scale.set_editor_property("parameter_name", "DepthScale")

    enabled = MEL.create_material_expression(
        mat, unreal.MaterialExpressionScalarParameter, -850, 1050
    )
    enabled.set_editor_property("parameter_name", "ForegroundFOVEnabled")
    enabled.set_editor_property("default_value", 0.0)

    try_connect(
        tan_fov,
        "",
        call,
        ["Foreground FOV (S)", "Foreground FOV", "ForegroundFOV"],
        "TanFOV",
    )
    try_connect(
        depth_scale,
        "",
        call,
        ["Depth Scale (S)", "Depth Scale", "DepthScale"],
        "DepthScale",
    )
    try_connect(
        enabled,
        "",
        call,
        ["Enable Foreground FOV (S)", "Enable Foreground FOV", "EnableForegroundFOV"],
        "ForegroundFOVEnabled",
    )

    MEL.recompile_material(mat)
    saved = unreal.EditorAssetLibrary.save_asset(path, only_if_is_dirty=False)
    unreal.log(f"[fpswitch] {name}: placed, saved={saved}")

unreal.log(
    "[fpswitch] DONE - in EACH material: (1) wire old final WPO Add -> "
    "'Base World Position Offset (V3)'; (2) wire MF WPO out -> World Position "
    "Offset pin; (3) DELETE old FOV node, MF_Foreground_FOVCorrection call and "
    "'FOV ADD' Add; (4) verify both Collection Param dropdowns resolved "
    "TanFOV/DepthScale; save both"
)
