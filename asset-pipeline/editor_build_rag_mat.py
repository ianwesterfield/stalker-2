# Rebuild M_MolotovRag with a tangent-free droop axis:
#   axis = normalize(TransformVector_Local->World(0,0,-1))   (rest tail dir)
#   WPO  = ((0,0,-1) - axis) * VertexColor.R * 14 * 0.75 + flutter
# Connects BaseColor/Roughness by script; WPO must be wired BY HAND:
#   open M_MolotovRag, drag the LAST Add node (far right) -> World Position
#   Offset pin, save.  Run:  py "<this file>"
import unreal

PLUGIN = "/MolotovBottle"
lib = unreal.MaterialEditingLibrary
tools = unreal.AssetToolsHelpers.get_asset_tools()

rag_path = f"{PLUGIN}/M_MolotovRag"
if unreal.EditorAssetLibrary.does_asset_exist(rag_path):
    unreal.EditorAssetLibrary.delete_asset(rag_path)
mat = tools.create_asset(
    "M_MolotovRag", PLUGIN, unreal.Material, unreal.MaterialFactoryNew()
)
mat.set_editor_property("two_sided", True)
try:
    mat.set_editor_property("used_with_skeletal_mesh", True)
except Exception as e:
    unreal.log(f"usage flag not scriptable ({e}) — preview + save will set it")


def ex(cls, x, y, **props):
    node = lib.create_material_expression(mat, cls, x, y)
    for k, v in props.items():
        node.set_editor_property(k, v)
    return node


cloth = unreal.EditorAssetLibrary.load_asset(f"{PLUGIN}/T_RagCloth")
ts = ex(unreal.MaterialExpressionTextureSample, -600, -300, texture=cloth)
lib.connect_material_property(ts, "RGB", unreal.MaterialProperty.MP_BASE_COLOR)
rough = ex(unreal.MaterialExpressionConstant, -600, -150, r=0.95)
lib.connect_material_property(rough, "", unreal.MaterialProperty.MP_ROUGHNESS)

# droop chain
vc = ex(unreal.MaterialExpressionVertexColor, -1200, 150)
local_down = ex(
    unreal.MaterialExpressionConstant3Vector,
    -1200,
    300,
    constant=unreal.LinearColor(0.0, 0.0, -1.0, 0.0),
)
xform = ex(
    unreal.MaterialExpressionTransform,
    -1000,
    300,
    transform_source_type=unreal.MaterialVectorCoordTransformSource.TRANSFORMSOURCE_LOCAL,
    transform_type=unreal.MaterialVectorCoordTransform.TRANSFORM_WORLD,
)
lib.connect_material_expressions(local_down, "", xform, "")
norm = ex(unreal.MaterialExpressionNormalize, -850, 300)
lib.connect_material_expressions(xform, "", norm, "")
world_down = ex(
    unreal.MaterialExpressionConstant3Vector,
    -1000,
    450,
    constant=unreal.LinearColor(0.0, 0.0, -1.0, 0.0),
)
delta = ex(unreal.MaterialExpressionSubtract, -700, 380)
lib.connect_material_expressions(world_down, "", delta, "A")
lib.connect_material_expressions(norm, "", delta, "B")

hang_scale = ex(
    unreal.MaterialExpressionConstant, -1000, 150, r=10.5
)  # 14cm * 0.75 stiffness
hang = ex(unreal.MaterialExpressionMultiply, -850, 150)
lib.connect_material_expressions(vc, "R", hang, "A")
lib.connect_material_expressions(hang_scale, "", hang, "B")
droop = ex(unreal.MaterialExpressionMultiply, -550, 250)
lib.connect_material_expressions(delta, "", droop, "A")
lib.connect_material_expressions(hang, "", droop, "B")

# flutter: small sine wiggle, scaled by hang weight
t = ex(unreal.MaterialExpressionTime, -1200, 600)
tspeed = ex(unreal.MaterialExpressionConstant, -1200, 700, r=5.0)
tmul = ex(unreal.MaterialExpressionMultiply, -1050, 620)
lib.connect_material_expressions(t, "", tmul, "A")
lib.connect_material_expressions(tspeed, "", tmul, "B")
phase_scale = ex(unreal.MaterialExpressionConstant, -1050, 740, r=3.0)
phase = ex(unreal.MaterialExpressionMultiply, -900, 700)
lib.connect_material_expressions(vc, "R", phase, "A")
lib.connect_material_expressions(phase_scale, "", phase, "B")
sin_in = ex(unreal.MaterialExpressionAdd, -750, 640)
lib.connect_material_expressions(tmul, "", sin_in, "A")
lib.connect_material_expressions(phase, "", sin_in, "B")
sine = ex(unreal.MaterialExpressionSine, -620, 640)
lib.connect_material_expressions(sin_in, "", sine, "")
fl_dir = ex(
    unreal.MaterialExpressionConstant3Vector,
    -620,
    760,
    constant=unreal.LinearColor(0.25, 0.25, 0.0, 0.0),
)
fl = ex(unreal.MaterialExpressionMultiply, -480, 680)
lib.connect_material_expressions(sine, "", fl, "A")
lib.connect_material_expressions(fl_dir, "", fl, "B")
flw = ex(unreal.MaterialExpressionMultiply, -350, 600)
lib.connect_material_expressions(fl, "", flw, "A")
lib.connect_material_expressions(vc, "R", flw, "B")

wpo = ex(unreal.MaterialExpressionAdd, -200, 400)
lib.connect_material_expressions(droop, "", wpo, "A")
lib.connect_material_expressions(flw, "", wpo, "B")

lib.recompile_material(mat)
unreal.EditorAssetLibrary.save_asset(rag_path)

# put it on the rag slot (replaces the debug material)
sk = unreal.EditorAssetLibrary.load_asset(f"{PLUGIN}/SK_MolotovBottle")
mats = list(sk.get_editor_property("materials"))
for i, sm in enumerate(mats):
    if str(sm.get_editor_property("material_slot_name")) == "MI_molotov_rag":
        mats[i] = unreal.SkeletalMaterial(
            material_interface=mat,
            material_slot_name=sm.get_editor_property("material_slot_name"),
        )
        unreal.log(f"rag slot {i} -> M_MolotovRag")
sk.set_editor_property("materials", mats)
unreal.log(
    "RAG_MAT_DONE — NOW: open M_MolotovRag, wire the rightmost Add -> World Position Offset, save"
)
