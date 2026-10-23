# Fix M_RagFlame cook failure: VertexColor's "" output is RGB (float3), so the
# alpha-only ComponentMask added by editor_tune2 can't translate. Rewire the
# blue-burn lerp's Alpha from the node's dedicated A output; the dead mask
# becomes unreachable and drops out of translation.
# Run in editor:  py "<this file>"
import unreal

MEL = unreal.MaterialEditingLibrary
EAL = unreal.EditorAssetLibrary
FLAME = "/MolotovBottle/M_RagFlame"

mat = EAL.load_asset(FLAME)
assert mat, "M_RagFlame missing"


def subobjects(cls_name, limit=96):
    found = []
    for n in range(limit):
        o = unreal.load_object(None, f"{FLAME}.M_RagFlame:{cls_name}_{n}")
        if o:
            found.append(o)
    return found


vcs = subobjects("MaterialExpressionVertexColor")
assert vcs, "VertexColor not found"
lerps = subobjects("MaterialExpressionLinearInterpolate")
assert len(lerps) == 1, f"expected 1 lerp, found {len(lerps)}"
assert MEL.connect_material_expressions(vcs[0], "A", lerps[0], "Alpha"), "rewire failed"
MEL.recompile_material(mat)
EAL.save_asset(FLAME)
unreal.log("FLAME_ALPHA_FIXED saved")
