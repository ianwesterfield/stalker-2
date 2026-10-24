# Make the flame gravity-bend clamp a scalar param (BendClamp, default 0.75)
# IN PLACE on M_RagFlame — in-hand look unchanged, but the throw hook can now
# tame the in-flight comet per-MID (no recook to iterate flight values).
# Headless: pipeline junction pattern, or GUI: py "<this file>"
import unreal

MEL = unreal.MaterialEditingLibrary
EAL = unreal.EditorAssetLibrary
FLAME = "/MolotovBottle/M_RagFlame"

# commandlet-safe: force the registry scan the headless boot skips
unreal.AssetRegistryHelpers.get_asset_registry().scan_paths_synchronous(
    ["/MolotovBottle"], force_rescan=True
)
mat = EAL.load_asset(FLAME)
assert mat, "M_RagFlame missing"


def subobjects(cls_name, limit=96):
    found = []
    for n in range(limit):
        o = unreal.load_object(None, f"{FLAME}.M_RagFlame:{cls_name}_{n}")
        if o:
            found.append(o)
    return found


for e in subobjects("MaterialExpressionScalarParameter"):
    if str(e.get_editor_property("parameter_name")) == "BendClamp":
        raise SystemExit(
            "BendClamp already wired — tune the param instead of rerunning"
        )

clamp = None
for e in subobjects("MaterialExpressionClamp"):
    if abs(e.get_editor_property("min_default") + 0.75) < 1e-4:
        clamp = e
        break
assert clamp, "gravity-bend Clamp (min_default -0.75) not found"

par = MEL.create_material_expression(
    mat, unreal.MaterialExpressionScalarParameter, -980, 820
)
par.set_editor_property("parameter_name", "BendClamp")
par.set_editor_property("default_value", 0.75)
neg = MEL.create_material_expression(mat, unreal.MaterialExpressionMultiply, -860, 880)
neg.set_editor_property("const_b", -1.0)
assert MEL.connect_material_expressions(par, "", neg, "A")
assert MEL.connect_material_expressions(par, "", clamp, "Max")
assert MEL.connect_material_expressions(neg, "", clamp, "Min")

MEL.recompile_material(mat)
assert EAL.save_asset(FLAME, only_if_is_dirty=False)
unreal.log("BENDCLAMP wired: clamp min/max = -/+ BendClamp(0.75)")
