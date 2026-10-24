# Add a burning-alcohol film to M_MolotovRag IN PLACE (no rebuild — the
# hand-wired droop->WPO and FOV-switch graphs survive): the whole cloth glows
# a faint animated blue, so the card flames read as licks rising off a
# burning rag instead of spot fires sitting on wet cloth.
# BurnGlow scalar param = live-tunable via MID (droop.lua PARAM="BurnGlow").
# Run in editor:  py "<this file>"
import unreal

MEL = unreal.MaterialEditingLibrary
EAL = unreal.EditorAssetLibrary
RAG = "/MolotovBottle/M_MolotovRag"

mat = EAL.load_asset(RAG)
assert mat, "M_MolotovRag missing"
t_noise = EAL.load_asset("/MolotovBottle/T_FlameNoise")
assert t_noise, "T_FlameNoise missing"


def subobjects(cls_name, limit=96):
    found = []
    for n in range(limit):
        o = unreal.load_object(None, f"{RAG}.M_MolotovRag:{cls_name}_{n}")
        if o:
            found.append(o)
    return found


for e in subobjects("MaterialExpressionScalarParameter"):
    if str(e.get_editor_property("parameter_name")) == "BurnGlow":
        raise SystemExit("BurnGlow already wired — tune the param instead of rerunning")


def node(cls, x, y, **props):
    e = MEL.create_material_expression(mat, cls, x, y)
    for k, v in props.items():
        e.set_editor_property(k, v)
    return e


def wire(src, out, dst, pin):
    assert MEL.connect_material_expressions(src, out, dst, pin), f"{out}->{pin} failed"


uv = node(unreal.MaterialExpressionTextureCoordinate, -1500, -700)
# U runs DOWN the tail -> negative U pan = the film crawls UP the cloth
pan_a = node(unreal.MaterialExpressionPanner, -1300, -750, speed_x=-0.22, speed_y=0.04)
wire(uv, "", pan_a, "Coordinate")
smp_a = node(
    unreal.MaterialExpressionTextureSample,
    -1100,
    -750,
    texture=t_noise,
    sampler_type=unreal.MaterialSamplerType.SAMPLERTYPE_LINEAR_COLOR,
)
wire(pan_a, "", smp_a, "UVs")

uv_b = node(unreal.MaterialExpressionMultiply, -1300, -600, const_b=2.3)
wire(uv, "", uv_b, "A")
pan_b = node(unreal.MaterialExpressionPanner, -1150, -600, speed_x=-0.5, speed_y=-0.07)
wire(uv_b, "", pan_b, "Coordinate")
smp_b = node(
    unreal.MaterialExpressionTextureSample,
    -950,
    -600,
    texture=t_noise,
    sampler_type=unreal.MaterialSamplerType.SAMPLERTYPE_LINEAR_COLOR,
)
wire(pan_b, "", smp_b, "UVs")

film = node(unreal.MaterialExpressionMultiply, -760, -680)
wire(smp_a, "R", film, "A")
wire(smp_b, "R", film, "B")
# bias so the film never fully dies between noise crests
base = node(unreal.MaterialExpressionAdd, -620, -680, const_b=0.35)
wire(film, "", base, "A")

blue_c = node(
    unreal.MaterialExpressionConstant3Vector,
    -620,
    -540,
    constant=unreal.LinearColor(0.12, 0.28, 1.0, 0.0),
)
tinted = node(unreal.MaterialExpressionMultiply, -460, -640)
wire(base, "", tinted, "A")
wire(blue_c, "", tinted, "B")
glow = node(
    unreal.MaterialExpressionScalarParameter,
    -460,
    -500,
    parameter_name="BurnGlow",
    default_value=0.8,
)
out = node(unreal.MaterialExpressionMultiply, -300, -600)
wire(tinted, "", out, "A")
wire(glow, "", out, "B")
MEL.connect_material_property(out, "", unreal.MaterialProperty.MP_EMISSIVE_COLOR)
MEL.recompile_material(mat)
EAL.save_asset(RAG)
unreal.log("RAG_BURN wired: emissive = noise film * blue * BurnGlow(0.8)")
