# Rebuild M_MolotovRag v2: droop axis = VertexTangentWS (tail UVs now run U
# down the cloth, so recomputed tangents are a SKINNED droop axis — the old
# Transform(Local->World) read component space, which the hand bone never
# rotates, hence no droop in game). Cloth texture sampled through a UV swizzle
# to undo the rotation. After running: wire the rightmost Add -> World
# Position Offset by hand, save.  Run:  py "<this file>"
import unreal

PLUGIN = "/MolotovBottle"
MEL = unreal.MaterialEditingLibrary
EAL = unreal.EditorAssetLibrary

cloth_tex = EAL.load_asset(f"{PLUGIN}/T_RagCloth")
assert cloth_tex, "T_RagCloth missing"

rag_path = f"{PLUGIN}/M_MolotovRag"
if EAL.does_asset_exist(rag_path):
    EAL.delete_asset(rag_path)
mat = unreal.AssetToolsHelpers.get_asset_tools().create_asset(
    "M_MolotovRag", PLUGIN, unreal.Material, unreal.MaterialFactoryNew()
)
mat.set_editor_property("two_sided", True)
try:
    mat.set_editor_property("used_with_skeletal_mesh", True)
except Exception:
    pass


def node(cls, x, y, **props):
    e = MEL.create_material_expression(mat, cls, x, y)
    for k, v in props.items():
        e.set_editor_property(k, v)
    return e


def wire(src, out, dst, pin):
    assert MEL.connect_material_expressions(src, out, dst, pin), f"{out}->{pin} failed"


# cloth sample: mesh UVs are (along-tail, across) — texture wants (across, along):
# sample at (1 - V, U)
tc = node(unreal.MaterialExpressionTextureCoordinate, -1100, -300)
m_u = node(
    unreal.MaterialExpressionComponentMask,
    -950,
    -350,
    r=True,
    g=False,
    b=False,
    a=False,
)
wire(tc, "", m_u, "")
m_v = node(
    unreal.MaterialExpressionComponentMask,
    -950,
    -250,
    r=False,
    g=True,
    b=False,
    a=False,
)
wire(tc, "", m_v, "")
inv_v = node(unreal.MaterialExpressionOneMinus, -800, -250)
wire(m_v, "", inv_v, "")
suv = node(unreal.MaterialExpressionAppendVector, -650, -300)
wire(inv_v, "", suv, "A")
wire(m_u, "", suv, "B")
cloth = node(
    unreal.MaterialExpressionTextureSample,
    -480,
    -300,
    texture=cloth_tex,
    sampler_type=unreal.MaterialSamplerType.SAMPLERTYPE_COLOR,
)
wire(suv, "", cloth, "UVs")
MEL.connect_material_property(cloth, "RGB", unreal.MaterialProperty.MP_BASE_COLOR)
rough = node(unreal.MaterialExpressionConstant, -480, -100, r=0.95)
MEL.connect_material_property(rough, "", unreal.MaterialProperty.MP_ROUGHNESS)

# droop: tangent IS the skinned along-cloth direction
vc = node(unreal.MaterialExpressionVertexColor, -1200, 150)
weight = node(
    unreal.MaterialExpressionComponentMask,
    -1050,
    150,
    r=True,
    g=False,
    b=False,
    a=False,
)
wire(vc, "", weight, "")
tan_ws = node(unreal.MaterialExpressionVertexTangentWS, -1200, 320)
world_down = node(
    unreal.MaterialExpressionConstant3Vector,
    -1200,
    450,
    constant=unreal.LinearColor(0.0, 0.0, -1.0, 0.0),
)
delta = node(unreal.MaterialExpressionSubtract, -1000, 380)
wire(world_down, "", delta, "A")
wire(tan_ws, "", delta, "B")
# small: rest tangent deviates from down wherever the drape curves, so this
# scales permanent rest-pose flare as much as tilt response
hang_scale = node(
    unreal.MaterialExpressionScalarParameter,
    -1050,
    260,
    parameter_name="DroopStrength",
    default_value=3.5,
)
hang = node(unreal.MaterialExpressionMultiply, -880, 220)
wire(weight, "", hang, "A")
wire(hang_scale, "", hang, "B")
droop = node(unreal.MaterialExpressionMultiply, -700, 300)
wire(delta, "", droop, "A")
wire(hang, "", droop, "B")

# flutter
t = node(unreal.MaterialExpressionTime, -1200, 650)
tspeed = node(unreal.MaterialExpressionConstant, -1200, 750, r=5.0)
tmul = node(unreal.MaterialExpressionMultiply, -1050, 670)
wire(t, "", tmul, "A")
wire(tspeed, "", tmul, "B")
phase_scale = node(unreal.MaterialExpressionConstant, -1050, 790, r=3.0)
phase = node(unreal.MaterialExpressionMultiply, -900, 750)
wire(weight, "", phase, "A")
wire(phase_scale, "", phase, "B")
sin_in = node(unreal.MaterialExpressionAdd, -750, 700)
wire(tmul, "", sin_in, "A")
wire(phase, "", sin_in, "B")
fsine = node(unreal.MaterialExpressionSine, -620, 700)
wire(sin_in, "", fsine, "")
fl_dir = node(
    unreal.MaterialExpressionConstant3Vector,
    -620,
    820,
    constant=unreal.LinearColor(0.25, 0.25, 0.0, 0.0),
)
fl = node(unreal.MaterialExpressionMultiply, -480, 740)
wire(fsine, "", fl, "A")
wire(fl_dir, "", fl, "B")
flw = node(unreal.MaterialExpressionMultiply, -350, 660)
wire(fl, "", flw, "A")
wire(weight, "", flw, "B")

wpo = node(unreal.MaterialExpressionAdd, -180, 450)
wire(droop, "", wpo, "A")
wire(flw, "", wpo, "B")

try:
    MEL.connect_material_property(
        wpo, "", unreal.MaterialProperty.MP_WORLD_POSITION_OFFSET
    )
    wired = True
except Exception:
    wired = False

MEL.recompile_material(mat)
EAL.save_asset(rag_path)
unreal.log(
    "RAG_MAT2_DONE — WPO auto-wired"
    if wired
    else "RAG_MAT2_DONE — wire the rightmost Add -> World Position Offset, save"
)
