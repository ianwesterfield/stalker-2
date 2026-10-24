"""One-boot recon #2: M_VFX_Fire_Cin_4 internals via package-subobject walk
(MaterialEditingLibrary.get_material_expressions missing in this drop)."""

import unreal

MAT = "/Game/_Stalker_2/VFX/Cinematic/E06_MQ02/M_VFX_Fire_Cin_4"
mat = unreal.EditorAssetLibrary.load_asset(MAT)
assert mat, "material not found"
pkg = unreal.load_package(MAT)

unreal.log(f"[cin4] loaded {mat.get_path_name()}")
for prop in (
    "blend_mode",
    "shading_model",
    "two_sided",
    "translucency_lighting_mode",
    "use_material_attributes",
):
    try:
        unreal.log(f"[cin4] {prop} = {mat.get_editor_property(prop)}")
    except Exception as e:
        unreal.log(f"[cin4] {prop} FAIL {e}")

for obj in unreal.ObjectIterator():
    try:
        if obj.get_outermost() != pkg or obj is mat:
            continue
    except Exception:
        continue
    cn = type(obj).__name__
    if not cn.startswith("MaterialExpression"):
        continue
    line = f"[cin4] EXPR {cn}"
    for prop, fmt in (
        ("texture", lambda v: v.get_path_name() if v else None),
        ("parameter_name", str),
        ("default_value", str),
        ("constant", str),
        ("r", str),
        ("speed_x", str),
        ("speed_y", str),
        ("coordinate_index", str),
    ):
        try:
            v = obj.get_editor_property(prop)
            line += f" {prop}={fmt(v)}"
        except Exception:
            pass
    unreal.log(line)

unreal.log("[cin4] DONE")
