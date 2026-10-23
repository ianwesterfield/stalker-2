"""Dump internals of vanilla Foreground material functions via subobject probing.

Run in Zone Kit Output Log (Cmd):
  py "C:\\Code\\westerfield.cloud\\Gaming\\stalker-2\\asset-pipeline\\editor_inspect_mf.py"
"""

import unreal

MFS = [
    "/Game/_Stalker_2/Materials/MaterialFunctions/Foreground/MF_ForegroundWithShadowSwitch",
    "/Game/_Stalker_2/Materials/MaterialFunctions/Foreground/MF_Foreground",
    "/Game/_Stalker_2/Materials/MaterialFunctions/Foreground/MF_Foreground_FOVCorrection",
]

CLASSES = [
    "MaterialExpressionFunctionInput",
    "MaterialExpressionFunctionOutput",
    "MaterialExpressionMaterialFunctionCall",
    "MaterialExpressionCustom",
    "MaterialExpressionShadowReplace",
    "MaterialExpressionStaticSwitchParameter",
    "MaterialExpressionStaticSwitch",
    "MaterialExpressionLinearInterpolate",
    "MaterialExpressionIf",
    "MaterialExpressionAdd",
    "MaterialExpressionSubtract",
    "MaterialExpressionMultiply",
    "MaterialExpressionDivide",
    "MaterialExpressionWorldPosition",
    "MaterialExpressionCameraPositionWS",
    "MaterialExpressionTransformPosition",
    "MaterialExpressionTransform",
    "MaterialExpressionComponentMask",
    "MaterialExpressionAppendVector",
    "MaterialExpressionConstant",
    "MaterialExpressionConstant3Vector",
    "MaterialExpressionCollectionParameter",
    "MaterialExpressionScalarParameter",
    "MaterialExpressionOneMinus",
    "MaterialExpressionNormalize",
    "MaterialExpressionDotProduct",
    "MaterialExpressionViewProperty",
    "MaterialExpressionScreenPosition",
    "MaterialExpressionPixelDepth",
]
MAX_INDEX = 30


def describe(expr):
    cls = type(expr).__name__.replace("MaterialExpression", "")
    extra = []
    for prop in (
        "input_name",
        "output_name",
        "parameter_name",
        "desc",
        "default_value",
        "code",
        "transform_source_type",
        "transform_type",
        "property_",
    ):
        try:
            v = expr.get_editor_property(prop)
            if v not in (None, ""):
                s = str(v)
                if len(s) > 220:
                    s = s[:220] + "..."
                extra.append(f"{prop}={s}")
        except Exception:
            pass
    if cls == "MaterialFunctionCall":
        try:
            fn = expr.get_editor_property("material_function")
            extra.append(f"fn={fn.get_name() if fn else None}")
        except Exception:
            pass
    label = f"{cls}[{expr.get_name()}]"
    return f"{label} {{{'; '.join(extra)}}}" if extra else label


for mf_path in MFS:
    name = mf_path.rsplit("/", 1)[1]
    unreal.EditorAssetLibrary.load_asset(mf_path)
    unreal.log(f"[mfdump] ===== {name} =====")
    for cls in CLASSES:
        for i in range(MAX_INDEX):
            obj = unreal.load_object(None, f"{mf_path}.{name}:{cls}_{i}")
            if obj:
                unreal.log(f"[mfdump]   {describe(obj)}")

unreal.log("[mfdump] done")
