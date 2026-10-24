"""Rebuild M_MolotovRag's WPO droop as a sign-free world-down chain.

Old droop derived its push axis from tangent x vertex-color-sign tricks that
jitter on the curved drape (solidify rim normals have no stable radial side)
-> stray shards floating off the bottle. New form:

    Base WPO = (float3(0,0,-1) - VertexTangentWS) * vcR * DroopStrength

Tangent = UV U direction = down-cloth on BOTH solidify sheets (handedness
flips between sheets, the tangent vector itself doesn't) -> no G-channel
compensation, floaters structurally impossible. On the plumb section the
tangent already points world-down when the bottle is upright -> delta ~= 0,
no rest flare; tilting the bottle grows the delta and the hem chases world
down -- the droop response being restored.

Only the FOV switch call's Base-WPO function input is (re)wired, which is
python-reachable; the hand-wired 'MF WPO out -> material WPO pin' hop is
untouched. The old droop subtree is left orphaned from the WPO path (nodes
shared with the colour chains keep compiling there).

Run headless with the plugin junction up; success sentinel RAG_DROOP_DONE.
"""

import unreal

PLUGIN = "/MolotovBottle"
NAME = "M_MolotovRag"
PATH = f"{PLUGIN}/{NAME}"
MEL = unreal.MaterialEditingLibrary

# commandlets skip the full registry scan -- plugin assets invisible without this
unreal.AssetRegistryHelpers.get_asset_registry().scan_paths_synchronous(
    [PLUGIN], force_rescan=True
)
mat = unreal.EditorAssetLibrary.load_asset(PATH)
assert mat, "M_MolotovRag missing (junction up?)"


def sub(cls_name, idx):
    return unreal.load_object(None, f"{PATH}.{NAME}:{cls_name}_{idx}")


mfcall = sub("MaterialExpressionMaterialFunctionCall", 2)
assert mfcall, "FOV switch MaterialFunctionCall_2 not found"
droop_param = sub("MaterialExpressionScalarParameter", 0)
pname = droop_param and str(droop_param.get_editor_property("parameter_name"))
assert pname == "DroopStrength", f"ScalarParameter_0 is {pname}, expected DroopStrength"

down = MEL.create_material_expression(
    mat, unreal.MaterialExpressionVectorParameter, -1600, 1400
)
# lua repoints this per-context: world-down default; pinned up+right in flight
down.set_editor_property("parameter_name", "DroopDir")
down.set_editor_property("default_value", unreal.LinearColor(0.0, 0.0, -1.0, 0.0))

tang = MEL.create_material_expression(
    mat, unreal.MaterialExpressionVertexTangentWS, -1600, 1520
)

delta = MEL.create_material_expression(
    mat, unreal.MaterialExpressionSubtract, -1400, 1450
)
ok = [
    MEL.connect_material_expressions(down, "", delta, "A"),
    MEL.connect_material_expressions(tang, "", delta, "B"),
]

vc = MEL.create_material_expression(
    mat, unreal.MaterialExpressionVertexColor, -1400, 1580
)

m1 = MEL.create_material_expression(mat, unreal.MaterialExpressionMultiply, -1200, 1480)
ok += [
    MEL.connect_material_expressions(delta, "", m1, "A"),
    # dedicated R output pin -- masking the '' RGB output fails at cook
    MEL.connect_material_expressions(vc, "R", m1, "B"),
]

m2 = MEL.create_material_expression(mat, unreal.MaterialExpressionMultiply, -1050, 1500)
ok += [
    MEL.connect_material_expressions(m1, "", m2, "A"),
    MEL.connect_material_expressions(droop_param, "", m2, "B"),
]
m2.set_editor_property(
    "desc", "NEW DROOP: (DroopDir - tangent) * vcR * DroopStrength -> Base WPO"
)

unreal.log(f"[ragdroop] chain wires: {ok}")
assert all(ok), "droop chain wiring failed"

wired = None
for pin in [
    "Base World Position Offset (V3)",
    "Base World Position Offset",
    "BaseWorldPositionOffset",
    "Base WPO (V3)",
    "Base WPO",
]:
    if MEL.connect_material_expressions(m2, "", mfcall, pin):
        wired = pin
        break
unreal.log(f"[ragdroop] Base WPO input pin: {wired}")
assert wired, "could not reach FOV switch Base WPO input -- old chain left intact"

MEL.recompile_material(mat)
saved = unreal.EditorAssetLibrary.save_asset(PATH, only_if_is_dirty=False)
unreal.log(f"[ragdroop] saved={saved}")
unreal.log("RAG_DROOP_DONE")
