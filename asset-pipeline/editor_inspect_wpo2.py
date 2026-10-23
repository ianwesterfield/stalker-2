"""WPO inspector v2 - probes material expression subobjects by name
(load_object on "<pkg>.<mat>:<Class>_<N>") since the Expressions array and
the WPO MaterialProperty enum member are both inaccessible in this build.
Prints every found node and its input edges.

Run in Zone Kit Output Log (Cmd):
  py "C:\\Code\\westerfield.cloud\\Gaming\\stalker-2\\asset-pipeline\\editor_inspect_wpo2.py"
"""

import unreal

PLUGIN = "/MolotovBottle"
OURS = ["M_MolotovRag", "M_RagFlame"]
MEL = unreal.MaterialEditingLibrary

CLASSES = [
    "MaterialExpressionAdd",
    "MaterialExpressionSubtract",
    "MaterialExpressionMultiply",
    "MaterialExpressionMaterialFunctionCall",
    "MaterialExpressionWorldPosition",
    "MaterialExpressionScalarParameter",
    "MaterialExpressionCollectionParameter",
    "MaterialExpressionVertexColor",
    "MaterialExpressionConstant",
    "MaterialExpressionConstant2Vector",
    "MaterialExpressionConstant3Vector",
    "MaterialExpressionSine",
    "MaterialExpressionTime",
    "MaterialExpressionTextureSample",
    "MaterialExpressionTextureCoordinate",
    "MaterialExpressionVertexTangentWS",
    "MaterialExpressionVertexNormalWS",
    "MaterialExpressionCameraVectorWS",
    "MaterialExpressionComponentMask",
    "MaterialExpressionLinearInterpolate",
    "MaterialExpressionAppendVector",
    "MaterialExpressionPanner",
    "MaterialExpressionOneMinus",
    "MaterialExpressionPower",
    "MaterialExpressionClamp",
    "MaterialExpressionFresnel",
    "MaterialExpressionSaturate",
]
MAX_INDEX = 40


def describe(expr):
    cls = type(expr).__name__.replace("MaterialExpression", "")
    extra = []
    for prop in ("parameter_name", "desc"):
        try:
            v = expr.get_editor_property(prop)
            if v:
                extra.append(str(v))
        except Exception:
            pass
    if cls == "MaterialFunctionCall":
        try:
            fn = expr.get_editor_property("material_function")
            extra.append(f"fn={fn.get_name() if fn else None}")
        except Exception:
            pass
    if cls == "Constant":
        try:
            extra.append(f"r={expr.get_editor_property('r')}")
        except Exception:
            pass
    label = f"{cls}[{expr.get_name()}]"
    return f"{label}({', '.join(extra)})" if extra else label


for name in OURS:
    path = f"{PLUGIN}/{name}"
    mat = unreal.EditorAssetLibrary.load_asset(path)
    unreal.log(f"[inspect2] ===== {name} =====")
    found = []
    for cls in CLASSES:
        for i in range(MAX_INDEX):
            obj = unreal.load_object(None, f"{path}.{name}:{cls}_{i}")
            if obj:
                found.append(obj)
    unreal.log(f"[inspect2] {len(found)} expressions found")
    for expr in found:
        try:
            inputs = MEL.get_inputs_for_material_expression(mat, expr)
            srcs = ", ".join(describe(x) for x in inputs if x) or "-"
        except Exception as e:
            srcs = f"(inputs err: {e})"
        unreal.log(f"[inspect2]   {describe(expr)}  <==  {srcs}")

unreal.log("[inspect2] done")
