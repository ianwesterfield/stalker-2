# Rebuild M_RagFlame v2: droop term now uses the hijacked flame-axis normal —
# the cloth hangs opposite the flame axis, so skinned droop axis = -VertexNormalWS
# and delta = world_down + VertexNormalWS (the old Transform(Local->World) read
# component space, which the hand bone never rotates -> no droop in game).
# After running: wire the rightmost Add -> World Position Offset by hand, save.
# Run:  py "<this file>"
import unreal

PLUGIN = "/MolotovBottle"
MEL = unreal.MaterialEditingLibrary
EAL = unreal.EditorAssetLibrary

t_flame = EAL.load_asset(f"{PLUGIN}/T_RagFlame")
t_noise = EAL.load_asset(f"{PLUGIN}/T_FlameNoise")
assert t_flame and t_noise, "flame textures missing"

mat_path = f"{PLUGIN}/M_RagFlame"
if EAL.does_asset_exist(mat_path):
    EAL.delete_asset(mat_path)
mat = unreal.AssetToolsHelpers.get_asset_tools().create_asset(
    "M_RagFlame", PLUGIN, unreal.Material, unreal.MaterialFactoryNew()
)
mat.set_editor_property("blend_mode", unreal.BlendMode.BLEND_ADDITIVE)
mat.set_editor_property("shading_model", unreal.MaterialShadingModel.MSM_UNLIT)
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


X = unreal.MaterialExpressionTextureSample  # noqa: N816

uv = node(unreal.MaterialExpressionTextureCoordinate, -2200, 0)

# UV distortion
uv_a = node(unreal.MaterialExpressionMultiply, -2000, -300, const_b=1.5)
wire(uv, "", uv_a, "A")
pan_a = node(unreal.MaterialExpressionPanner, -1800, -300, speed_x=0.0, speed_y=0.35)
wire(uv_a, "", pan_a, "Coordinate")
smp_a = node(
    X,
    -1600,
    -300,
    texture=t_noise,
    sampler_type=unreal.MaterialSamplerType.SAMPLERTYPE_LINEAR_COLOR,
)
wire(pan_a, "", smp_a, "UVs")

uv_b = node(unreal.MaterialExpressionMultiply, -2000, -100, const_b=3.0)
wire(uv, "", uv_b, "A")
pan_b = node(unreal.MaterialExpressionPanner, -1800, -100, speed_x=0.07, speed_y=0.6)
wire(uv_b, "", pan_b, "Coordinate")
smp_b = node(
    X,
    -1600,
    -100,
    texture=t_noise,
    sampler_type=unreal.MaterialSamplerType.SAMPLERTYPE_LINEAR_COLOR,
)
wire(pan_b, "", smp_b, "UVs")

avg = node(unreal.MaterialExpressionAdd, -1350, -200)
wire(smp_a, "R", avg, "A")
wire(smp_b, "R", avg, "B")
half = node(unreal.MaterialExpressionMultiply, -1200, -200, const_b=0.5)
wire(avg, "", half, "A")
centered = node(unreal.MaterialExpressionSubtract, -1050, -200, const_b=0.5)
wire(half, "", centered, "A")

mask_v = node(
    unreal.MaterialExpressionComponentMask, -1350, 50, r=False, g=True, b=False, a=False
)
wire(uv, "", mask_v, "")
tipness = node(unreal.MaterialExpressionOneMinus, -1200, 50)
wire(mask_v, "", tipness, "")

dist = node(unreal.MaterialExpressionMultiply, -900, -150)
wire(centered, "", dist, "A")
wire(tipness, "", dist, "B")
dist_s = node(unreal.MaterialExpressionMultiply, -750, -150, const_b=0.12)
wire(dist, "", dist_s, "A")
dist2d = node(unreal.MaterialExpressionAppendVector, -600, -150)
wire(dist_s, "", dist2d, "A")
zero = node(unreal.MaterialExpressionConstant, -750, -20, r=0.0)
wire(zero, "", dist2d, "B")

uv_warp = node(unreal.MaterialExpressionAdd, -450, 0)
wire(uv, "", uv_warp, "A")
wire(dist2d, "", uv_warp, "B")
flame = node(
    X,
    -300,
    0,
    texture=t_flame,
    sampler_type=unreal.MaterialSamplerType.SAMPLERTYPE_COLOR,
)
wire(uv_warp, "", flame, "UVs")

# flicker
pan_f = node(unreal.MaterialExpressionPanner, -1800, 300, speed_x=0.11, speed_y=0.8)
wire(uv, "", pan_f, "Coordinate")
smp_f = node(
    X,
    -1600,
    300,
    texture=t_noise,
    sampler_type=unreal.MaterialSamplerType.SAMPLERTYPE_LINEAR_COLOR,
)
wire(pan_f, "", smp_f, "UVs")
flick_m = node(unreal.MaterialExpressionMultiply, -1350, 300, const_b=0.6)
wire(smp_f, "R", flick_m, "A")
flick = node(unreal.MaterialExpressionAdd, -1200, 300, const_b=0.7)
wire(flick_m, "", flick, "A")

# emissive
rgba = node(unreal.MaterialExpressionMultiply, -100, 0)
wire(flame, "RGB", rgba, "A")
wire(flame, "A", rgba, "B")
bright = node(unreal.MaterialExpressionMultiply, 50, 0, const_b=6.0)
wire(rgba, "", bright, "A")
pulsed = node(unreal.MaterialExpressionMultiply, 200, 50)
wire(bright, "", pulsed, "A")
wire(flick, "", pulsed, "B")
dfade = node(
    unreal.MaterialExpressionDepthFade,
    200,
    250,
    opacity_default=1.0,
    fade_distance_default=2.0,
)
seated = node(unreal.MaterialExpressionMultiply, 380, 100)
wire(pulsed, "", seated, "A")
wire(dfade, "", seated, "B")
MEL.connect_material_property(seated, "", unreal.MaterialProperty.MP_EMISSIVE_COLOR)
one = node(unreal.MaterialExpressionConstant, 380, 420, r=1.0)
MEL.connect_material_property(one, "", unreal.MaterialProperty.MP_OPACITY)

# vertex colors: R = droop weight, B = height above card base /20cm
vc = node(unreal.MaterialExpressionVertexColor, -1300, 500)
hgt = node(
    unreal.MaterialExpressionComponentMask,
    -1100,
    480,
    r=False,
    g=False,
    b=True,
    a=False,
)
wire(vc, "", hgt, "")
weight = node(
    unreal.MaterialExpressionComponentMask,
    -1100,
    580,
    r=True,
    g=False,
    b=False,
    a=False,
)
wire(vc, "", weight, "")

# gravity bend
vnorm = node(unreal.MaterialExpressionVertexNormalWS, -1000, 650)
world_up = node(
    unreal.MaterialExpressionConstant3Vector,
    -1000,
    800,
    constant=unreal.LinearColor(0.0, 0.0, 1.0, 0.0),
)
lean = node(unreal.MaterialExpressionSubtract, -820, 700)
wire(world_up, "", lean, "A")
wire(vnorm, "", lean, "B")
height_cm = node(unreal.MaterialExpressionMultiply, -820, 850, const_b=20.0)
wire(hgt, "", height_cm, "A")
bend = node(unreal.MaterialExpressionMultiply, -640, 750)
wire(lean, "", bend, "A")
wire(height_cm, "", bend, "B")

# sway
t = node(unreal.MaterialExpressionTime, -1000, 1000)
sin_x = node(unreal.MaterialExpressionSine, -820, 980, period=0.9)
wire(t, "", sin_x, "")
sin_y = node(unreal.MaterialExpressionSine, -820, 1080, period=0.57)
wire(t, "", sin_y, "")
sway_xy = node(unreal.MaterialExpressionAppendVector, -640, 1020)
wire(sin_x, "", sway_xy, "A")
wire(sin_y, "", sway_xy, "B")
sway_3d = node(unreal.MaterialExpressionAppendVector, -500, 1020)
wire(sway_xy, "", sway_3d, "A")
wire(zero, "", sway_3d, "B")
sway_amp = node(unreal.MaterialExpressionMultiply, -360, 980, const_b=0.5)
wire(sway_3d, "", sway_amp, "A")
sway = node(unreal.MaterialExpressionMultiply, -220, 920)
wire(sway_amp, "", sway, "A")
wire(tipness, "", sway, "B")

# droop: cloth direction = -flame axis -> delta = world_down + VertexNormalWS
world_down = node(
    unreal.MaterialExpressionConstant3Vector,
    -1000,
    1250,
    constant=unreal.LinearColor(0.0, 0.0, -1.0, 0.0),
)
delta = node(unreal.MaterialExpressionAdd, -800, 1300)
wire(world_down, "", delta, "A")
wire(vnorm, "", delta, "B")
# must match the rag's DroopStrength or the tip fire detaches from the cloth
hang_scale = node(
    unreal.MaterialExpressionScalarParameter,
    -1000,
    1150,
    parameter_name="DroopStrength",
    default_value=3.5,
)
hang = node(unreal.MaterialExpressionMultiply, -850, 1150)
wire(weight, "", hang, "A")
wire(hang_scale, "", hang, "B")
droop = node(unreal.MaterialExpressionMultiply, -650, 1200)
wire(delta, "", droop, "A")
wire(hang, "", droop, "B")

# flutter (same phase as the rag)
tspeed = node(unreal.MaterialExpressionConstant, -1300, 1550, r=5.0)
tmul = node(unreal.MaterialExpressionMultiply, -1100, 1550)
wire(t, "", tmul, "A")
wire(tspeed, "", tmul, "B")
phase_scale = node(unreal.MaterialExpressionConstant, -1100, 1650, r=3.0)
phase = node(unreal.MaterialExpressionMultiply, -950, 1620)
wire(weight, "", phase, "A")
wire(phase_scale, "", phase, "B")
sin_in = node(unreal.MaterialExpressionAdd, -800, 1570)
wire(tmul, "", sin_in, "A")
wire(phase, "", sin_in, "B")
fsine = node(unreal.MaterialExpressionSine, -670, 1570)
wire(sin_in, "", fsine, "")
fl_dir = node(
    unreal.MaterialExpressionConstant3Vector,
    -670,
    1690,
    constant=unreal.LinearColor(0.25, 0.25, 0.0, 0.0),
)
fl = node(unreal.MaterialExpressionMultiply, -530, 1610)
wire(fsine, "", fl, "A")
wire(fl_dir, "", fl, "B")
flw = node(unreal.MaterialExpressionMultiply, -400, 1550)
wire(fl, "", flw, "A")
wire(weight, "", flw, "B")

# WPO = bend + sway + droop + flutter  (rightmost Add -> wire by hand)
bs = node(unreal.MaterialExpressionAdd, -60, 850)
wire(bend, "", bs, "A")
wire(sway, "", bs, "B")
df = node(unreal.MaterialExpressionAdd, -200, 1300)
wire(droop, "", df, "A")
wire(flw, "", df, "B")
wpo = node(unreal.MaterialExpressionAdd, 120, 1050)
wire(bs, "", wpo, "A")
wire(df, "", wpo, "B")

try:
    MEL.connect_material_property(
        wpo, "", unreal.MaterialProperty.MP_WORLD_POSITION_OFFSET
    )
    wired = True
except Exception:
    wired = False

MEL.recompile_material(mat)
EAL.save_asset(mat_path)
unreal.log(
    "TIPFLAME_MAT2_DONE — WPO auto-wired"
    if wired
    else "TIPFLAME_MAT2_DONE — wire the rightmost Add (x~120) -> World Position Offset, save"
)
