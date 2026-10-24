# Build M_SheathFlame: the bonfire's 8x8 fire flipbook (T_fire_v02_8x8) played
# on the skinned engulf-sheath panels — bonfire burn, glued to the rag by
# construction. Flipbook UVs are built with explicit node math (no engine
# function-call pin guessing). Recolored blue roots -> red body via vcA.
# One-time, like editor_build_flame_mat.py; run headless with the junction up:
#   Stalker2ModEditor-Win64-Shipping-Cmd.exe <uproject> -run=pythonscript -script="<this>"
import unreal

PLUGIN = "/MolotovBottle"
GAME_FIRE_TEX = "/Game/_Stalker_2/VFX/Environment/BonFire/Textures/T_fire_v02_8x8"
# plugin-local copy: the mod cook strips cross-pak /Game texture refs (sampled
# black in-game), so we ship our own
FIRE_TEX = f"{PLUGIN}/T_fire_v02_8x8"
MEL = unreal.MaterialEditingLibrary
EAL = unreal.EditorAssetLibrary

unreal.AssetRegistryHelpers.get_asset_registry().scan_paths_synchronous(
    [PLUGIN, "/Game/_Stalker_2/VFX/Environment/BonFire"], force_rescan=True
)
assert EAL.does_directory_exist(f"{PLUGIN}/"), "plugin not mounted — junction first"

if not EAL.does_asset_exist(FIRE_TEX):
    unreal.log("PHASE: duplicate flipbook texture into plugin")
    assert EAL.duplicate_asset(GAME_FIRE_TEX, FIRE_TEX), "texture duplicate failed"
    assert EAL.save_asset(FIRE_TEX, only_if_is_dirty=False)
t_fire = EAL.load_asset(FIRE_TEX)
assert t_fire, "bonfire flipbook texture missing"

mat_path = f"{PLUGIN}/M_SheathFlame"
if EAL.does_asset_exist(mat_path):
    unreal.log("PHASE: delete old sheath material")
    EAL.delete_asset(mat_path)
unreal.log("PHASE: create sheath material")
mat = unreal.AssetToolsHelpers.get_asset_tools().create_asset(
    "M_SheathFlame", PLUGIN, unreal.Material, unreal.MaterialFactoryNew()
)
assert mat, "material create failed"
mat.set_editor_property("blend_mode", unreal.BlendMode.BLEND_ADDITIVE)
mat.set_editor_property("shading_model", unreal.MaterialShadingModel.MSM_UNLIT)
mat.set_editor_property("two_sided", True)


def node(cls, x, y, **props):
    e = MEL.create_material_expression(mat, cls, x, y)
    for k, v in props.items():
        e.set_editor_property(k, v)
    return e


def wire(src, out, dst, pin):
    assert MEL.connect_material_expressions(src, out, dst, pin), f"{out}->{pin} failed"


def scalar_param(name, default, x, y):
    p = node(unreal.MaterialExpressionScalarParameter, x, y)
    p.set_editor_property("parameter_name", name)
    p.set_editor_property("default_value", default)
    return p


unreal.log("PHASE: build graph")
uv = node(unreal.MaterialExpressionTextureCoordinate, -2300, 0)

# A: flipbook frame UVs — frame = floor(Time*FPS) % 64; cell = (col,row)/8
fps = scalar_param("FlipbookFPS", 18.0, -2300, -400)
t = node(unreal.MaterialExpressionTime, -2300, -250)
phase = node(unreal.MaterialExpressionMultiply, -2150, -330)
wire(t, "", phase, "A")
wire(fps, "", phase, "B")
frame_f = node(unreal.MaterialExpressionFloor, -2000, -330)
wire(phase, "", frame_f, "")
c64 = node(unreal.MaterialExpressionConstant, -2000, -200, r=64.0)
c8 = node(unreal.MaterialExpressionConstant, -2000, -120, r=8.0)
frame = node(unreal.MaterialExpressionFmod, -1850, -330)
wire(frame_f, "", frame, "A")
wire(c64, "", frame, "B")
col = node(unreal.MaterialExpressionFmod, -1700, -400)
wire(frame, "", col, "A")
wire(c8, "", col, "B")
row_div = node(unreal.MaterialExpressionMultiply, -1700, -260, const_b=0.125)
wire(frame, "", row_div, "A")
row = node(unreal.MaterialExpressionFloor, -1550, -260)
wire(row_div, "", row, "")
col_off = node(unreal.MaterialExpressionMultiply, -1550, -400, const_b=0.125)
wire(col, "", col_off, "A")
row_off = node(unreal.MaterialExpressionMultiply, -1400, -260, const_b=0.125)
wire(row, "", row_off, "A")
cell = node(unreal.MaterialExpressionAppendVector, -1250, -330)
wire(col_off, "", cell, "A")
wire(row_off, "", cell, "B")
uv_cell = node(unreal.MaterialExpressionMultiply, -1250, -150, const_b=0.125)
wire(uv, "", uv_cell, "A")
fb_uv = node(unreal.MaterialExpressionAdd, -1100, -250)
wire(uv_cell, "", fb_uv, "A")
wire(cell, "", fb_uv, "B")

# B: sample + luminance
flame = node(
    unreal.MaterialExpressionTextureSample,
    -950,
    -250,
    texture=t_fire,
    sampler_type=unreal.MaterialSamplerType.SAMPLERTYPE_COLOR,
)
wire(fb_uv, "", flame, "UVs")
desat = node(unreal.MaterialExpressionDesaturation, -750, -250)
wire(flame, "RGB", desat, "")
one_c = node(unreal.MaterialExpressionConstant, -950, -80, r=1.0)
wire(one_c, "", desat, "Fraction")
lum = node(
    unreal.MaterialExpressionComponentMask,
    -600,
    -250,
    r=True,
    g=False,
    b=False,
    a=False,
)
wire(desat, "", lum, "")

# C: blue->red recolor up the panel; vcA ramps 0 at roots -> 1 at ~2/3 height.
# vcA MUST come from the VertexColor node's dedicated "A" output (the "" output
# is float3 RGB; masking A off it fails cook translation)
vc = node(unreal.MaterialExpressionVertexColor, -750, 100)
blue = node(
    unreal.MaterialExpressionConstant3Vector,
    -750,
    220,
    constant=unreal.LinearColor(0.15, 0.3, 1.0, 0.0),
)
red = node(
    unreal.MaterialExpressionConstant3Vector,
    -750,
    360,
    constant=unreal.LinearColor(1.0, 0.28, 0.05, 0.0),
)
tint = node(unreal.MaterialExpressionLinearInterpolate, -550, 200)
wire(blue, "", tint, "A")
wire(red, "", tint, "B")
wire(vc, "A", tint, "Alpha")

lit = node(unreal.MaterialExpressionMultiply, -400, -100)
wire(tint, "", lit, "A")
wire(lum, "", lit, "B")
inten = scalar_param("SheathIntensity", 6.0, -400, 60)
bright = node(unreal.MaterialExpressionMultiply, -250, -60)
wire(lit, "", bright, "A")
wire(inten, "", bright, "B")

# D: depth seat — short fade so face-on fire over the cloth survives (the 2.0cm
# rag-flame fade erased flames wherever cloth sat right behind them)
dfade = node(unreal.MaterialExpressionDepthFade, -250, 160, opacity_default=1.0)
fade_d = scalar_param("SheathDepthFade", 0.5, -450, 240)
wire(fade_d, "", dfade, "FadeDistance")
seated = node(unreal.MaterialExpressionMultiply, -100, 0)
wire(bright, "", seated, "A")
wire(dfade, "", seated, "B")

# E: debug overlay — DebugUV=1 paints RG=panel UV, B=flipbook luminance, so
# panel placement/orientation can be verified live (droop.lua, no recook)
dbg_rg = node(unreal.MaterialExpressionAppendVector, -250, 420)
mask_u = node(
    unreal.MaterialExpressionComponentMask, -450, 380, r=True, g=False, b=False, a=False
)
wire(uv, "", mask_u, "")
mask_v = node(
    unreal.MaterialExpressionComponentMask, -450, 470, r=False, g=True, b=False, a=False
)
wire(uv, "", mask_v, "")
wire(mask_u, "", dbg_rg, "A")
wire(mask_v, "", dbg_rg, "B")
dbg_rgb = node(unreal.MaterialExpressionAppendVector, -100, 440)
wire(dbg_rg, "", dbg_rgb, "A")
dbg_b = node(unreal.MaterialExpressionMultiply, -250, 540, const_b=0.5)
wire(lum, "", dbg_b, "A")
wire(dbg_b, "", dbg_rgb, "B")
dbg_sw = scalar_param("DebugUV", 0.0, -100, 560)
emissive = node(unreal.MaterialExpressionLinearInterpolate, 80, 100)
wire(seated, "", emissive, "A")
wire(dbg_rgb, "", emissive, "B")
wire(dbg_sw, "", emissive, "Alpha")

# F: WPO — same proven recipe as M_RagFlame: custom normals are the flame axis,
# (world-up - VertexNormalWS) * height re-points the flame world-up; clamp is
# the BendClamp param so the flight hook tames it in the same breath
mask_v2 = node(
    unreal.MaterialExpressionComponentMask,
    -1000,
    700,
    r=False,
    g=True,
    b=False,
    a=False,
)
wire(uv, "", mask_v2, "")
tipness = node(unreal.MaterialExpressionOneMinus, -850, 700)  # UE V=0 at tip
wire(mask_v2, "", tipness, "")
vnorm = node(unreal.MaterialExpressionVertexNormalWS, -1000, 850)
world_up = node(
    unreal.MaterialExpressionConstant3Vector,
    -1000,
    1000,
    constant=unreal.LinearColor(0.0, 0.0, 1.0, 0.0),
)
lean = node(unreal.MaterialExpressionSubtract, -820, 900)
wire(world_up, "", lean, "A")
wire(vnorm, "", lean, "B")
height_cm = node(unreal.MaterialExpressionMultiply, -820, 1080, const_b=12.0)
wire(tipness, "", height_cm, "A")
bend = node(unreal.MaterialExpressionMultiply, -640, 950)
wire(lean, "", bend, "A")
wire(height_cm, "", bend, "B")
bclamp = scalar_param("BendClamp", 0.75, -640, 1120)
bneg = node(unreal.MaterialExpressionMultiply, -500, 1160, const_b=-1.0)
wire(bclamp, "", bneg, "A")
clamp = node(unreal.MaterialExpressionClamp, -460, 980)
wire(bend, "", clamp, "")
wire(bclamp, "", clamp, "Max")
wire(bneg, "", clamp, "Min")

t2 = node(unreal.MaterialExpressionTime, -1000, 1250)
sin_x = node(unreal.MaterialExpressionSine, -850, 1230, period=0.9)
wire(t2, "", sin_x, "")
sin_y = node(unreal.MaterialExpressionSine, -850, 1330, period=0.57)
wire(t2, "", sin_y, "")
sway_xy = node(unreal.MaterialExpressionAppendVector, -700, 1270)
wire(sin_x, "", sway_xy, "A")
wire(sin_y, "", sway_xy, "B")
zero = node(unreal.MaterialExpressionConstant, -700, 1380, r=0.0)
sway_3d = node(unreal.MaterialExpressionAppendVector, -560, 1290)
wire(sway_xy, "", sway_3d, "A")
wire(zero, "", sway_3d, "B")
sway_amp = node(unreal.MaterialExpressionMultiply, -420, 1290, const_b=0.5)
wire(sway_3d, "", sway_amp, "A")
sway = node(unreal.MaterialExpressionMultiply, -280, 1240)
wire(sway_amp, "", sway, "A")
wire(tipness, "", sway, "B")
wpo = node(unreal.MaterialExpressionAdd, -120, 1050)
wire(clamp, "", wpo, "A")
wire(sway, "", wpo, "B")

mma = node(unreal.MaterialExpressionMakeMaterialAttributes, 400, 400)
wire(emissive, "", mma, "EmissiveColor")
wire(wpo, "", mma, "WorldPositionOffset")
one = node(unreal.MaterialExpressionConstant, 250, 520, r=1.0)
wire(one, "", mma, "Opacity")
mat.set_editor_property("use_material_attributes", True)
MEL.connect_material_property(mma, "", unreal.MaterialProperty.MP_FRONT_MATERIAL)

unreal.log("PHASE: recompile")
MEL.recompile_material(mat)
unreal.log("PHASE: save")
assert EAL.save_asset(mat_path, only_if_is_dirty=False)
unreal.log("SHEATH_MAT_DONE: " + mat_path)
