# Build M_RagFlame material graph + wire it to SK_MolotovBottle, headless.
# Run (editor CLOSED):
#   Stalker2ModEditor-Win64-Shipping-Cmd.exe <uproject> -run=pythonscript -script="<this file>"
import unreal

PLUGIN = "/MolotovBottle"
OUT = r"c:\Code\westerfield.cloud\Gaming\stalker-2\asset-pipeline\out"
MEL = unreal.MaterialEditingLibrary
EAL = unreal.EditorAssetLibrary


def ensure_texture(name, srgb):
    path = f"{PLUGIN}/{name}"
    tex = EAL.load_asset(path) if EAL.does_asset_exist(path) else None
    if not tex:
        task = unreal.AssetImportTask()
        task.filename = f"{OUT}\\{name}.png"
        task.destination_path = PLUGIN
        task.destination_name = name
        task.automated = True
        task.replace_existing = True
        task.save = False
        unreal.AssetToolsHelpers.get_asset_tools().import_asset_tasks([task])
        tex = EAL.load_asset(path)
    assert tex, f"texture {path} missing and import failed"
    tex.set_editor_property("srgb", srgb)
    EAL.save_asset(path)
    unreal.log(f"texture ready: {path} srgb={srgb}")
    return tex


t_flame = ensure_texture("T_RagFlame", True)
t_noise = ensure_texture("T_FlameNoise", False)

# --- material ---
mat_path = f"{PLUGIN}/M_RagFlame"
# recreate from scratch: wiping a GUI-authored material in the commandlet AV'd
if EAL.does_asset_exist(mat_path):
    unreal.log("PHASE: delete old material")
    EAL.delete_asset(mat_path)
unreal.log("PHASE: create material")
mat = unreal.AssetToolsHelpers.get_asset_tools().create_asset(
    "M_RagFlame", PLUGIN, unreal.Material, unreal.MaterialFactoryNew()
)
assert mat, "material create failed"
unreal.log("PHASE: set material props")
mat.set_editor_property("blend_mode", unreal.BlendMode.BLEND_ADDITIVE)
mat.set_editor_property("shading_model", unreal.MaterialShadingModel.MSM_UNLIT)
mat.set_editor_property("two_sided", True)
unreal.log("PHASE: build graph")


def node(cls, x, y, **props):
    e = MEL.create_material_expression(mat, cls, x, y)
    for k, v in props.items():
        e.set_editor_property(k, v)
    return e


def wire(src, out, dst, pin):
    assert MEL.connect_material_expressions(src, out, dst, pin), f"{out}->{pin} failed"


X = unreal.MaterialExpressionTextureSample  # noqa: N816 (brevity alias)

uv = node(unreal.MaterialExpressionTextureCoordinate, -2200, 0)

# A: UV distortion — two panned noise samples, averaged, centered, tip-masked
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
wire(uv, "", mask_v, "")  # single-input nodes use the unnamed pin
tipness = node(unreal.MaterialExpressionOneMinus, -1200, 50)  # base V=1 -> 0 at roots
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

# C: flame sample through distorted UVs
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

# D: flicker — third noise pan remapped to 0.7..1.3
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

# E: emissive = rgb * a * 6 * flicker * depthfade
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

# F: WPO gravity bend — card normals are baked to the flame axis (bottle-up),
# and skinning rotates them, so (world-up - VertexNormalWS) * height-from-base
# repositions every vertex onto a world-upright flame regardless of bottle tilt.
vnorm = node(unreal.MaterialExpressionVertexNormalWS, -1000, 550)
world_up = node(
    unreal.MaterialExpressionConstant3Vector,
    -1000,
    700,
    constant=unreal.LinearColor(0.0, 0.0, 1.0, 0.0),
)
lean = node(unreal.MaterialExpressionSubtract, -820, 600)
wire(world_up, "", lean, "A")
wire(vnorm, "", lean, "B")
height_cm = node(unreal.MaterialExpressionMultiply, -820, 780, const_b=10.5)
wire(tipness, "", height_cm, "A")
bend = node(unreal.MaterialExpressionMultiply, -640, 650)
wire(lean, "", bend, "A")
wire(height_cm, "", bend, "B")

# G: gentle sway — two detuned sines so the tip wanders instead of metronoming
t = node(unreal.MaterialExpressionTime, -1000, 900)
sin_x = node(unreal.MaterialExpressionSine, -820, 880, period=0.9)
wire(t, "", sin_x, "")
sin_y = node(unreal.MaterialExpressionSine, -820, 980, period=0.57)
wire(t, "", sin_y, "")
sway_xy = node(unreal.MaterialExpressionAppendVector, -640, 920)
wire(sin_x, "", sway_xy, "A")
wire(sin_y, "", sway_xy, "B")
sway_3d = node(unreal.MaterialExpressionAppendVector, -500, 920)
wire(sway_xy, "", sway_3d, "A")
wire(zero, "", sway_3d, "B")
sway_amp = node(unreal.MaterialExpressionMultiply, -360, 880, const_b=0.5)
wire(sway_3d, "", sway_amp, "A")
sway = node(unreal.MaterialExpressionMultiply, -220, 820)
wire(sway_amp, "", sway, "A")
wire(tipness, "", sway, "B")

wpo = node(unreal.MaterialExpressionAdd, -60, 720)
wire(bend, "", wpo, "A")
wire(sway, "", wpo, "B")

# the scripting enum doesn't expose MP_WORLD_POSITION_OFFSET — go through
# material attributes, whose MP_FRONT_MATERIAL pin IS exposed
mma = node(unreal.MaterialExpressionMakeMaterialAttributes, 550, 300)
wire(seated, "", mma, "EmissiveColor")
wire(wpo, "", mma, "WorldPositionOffset")
one = node(unreal.MaterialExpressionConstant, 380, 420, r=1.0)
wire(one, "", mma, "Opacity")  # additive output = emissive * opacity
mat.set_editor_property("use_material_attributes", True)
MEL.connect_material_property(mma, "", unreal.MaterialProperty.MP_FRONT_MATERIAL)

unreal.log("PHASE: recompile")
MEL.recompile_material(mat)
unreal.log("PHASE: save material")
EAL.save_asset(mat_path)
unreal.log("material built: " + mat_path)
flame_mat_asset = mat

# --- M_MolotovRag: lit two-sided cloth with gravity-droop WPO ---
t_cloth = ensure_texture("T_RagCloth", True)
rag_path = f"{PLUGIN}/M_MolotovRag"
if EAL.does_asset_exist(rag_path):
    unreal.log("PHASE: delete old rag material")
    EAL.delete_asset(rag_path)
unreal.log("PHASE: create rag material")
mat = unreal.AssetToolsHelpers.get_asset_tools().create_asset(
    "M_MolotovRag", PLUGIN, unreal.Material, unreal.MaterialFactoryNew()
)
assert mat, "rag material create failed"
mat.set_editor_property("two_sided", True)
unreal.log("PHASE: build rag graph")

cloth = node(
    X,
    -400,
    0,
    texture=t_cloth,
    sampler_type=unreal.MaterialSamplerType.SAMPLERTYPE_COLOR,
)
rough = node(unreal.MaterialExpressionConstant, -400, 200, r=0.95)

# droop: hang axis = cross(tangent, normal) — both rotate with the skinning, so
# this tracks the bottle live; vertex colors carry R = hang distance (/14 cm),
# G = solidify-shell sign (inner shell's flipped normal inverts the cross)
vc = node(unreal.MaterialExpressionVertexColor, -1300, 500)
hang = node(
    unreal.MaterialExpressionComponentMask,
    -1100,
    450,
    r=True,
    g=False,
    b=False,
    a=False,
)
wire(vc, "", hang, "")
sgn_m = node(
    unreal.MaterialExpressionComponentMask,
    -1100,
    560,
    r=False,
    g=True,
    b=False,
    a=False,
)
wire(vc, "", sgn_m, "")
sgn2 = node(unreal.MaterialExpressionMultiply, -950, 560, const_b=2.0)
wire(sgn_m, "", sgn2, "A")
sgn = node(unreal.MaterialExpressionSubtract, -800, 560, const_b=1.0)
wire(sgn2, "", sgn, "A")

tan_ws = node(unreal.MaterialExpressionVertexTangentWS, -1300, 700)
nrm_ws = node(unreal.MaterialExpressionVertexNormalWS, -1300, 800)
axis_raw = node(unreal.MaterialExpressionCrossProduct, -1100, 740)
wire(tan_ws, "", axis_raw, "A")
wire(nrm_ws, "", axis_raw, "B")
axis = node(unreal.MaterialExpressionMultiply, -950, 700)
wire(axis_raw, "", axis, "A")
wire(sgn, "", axis, "B")

down = node(
    unreal.MaterialExpressionConstant3Vector,
    -950,
    850,
    constant=unreal.LinearColor(0.0, 0.0, -1.0, 0.0),
)
lean_r = node(unreal.MaterialExpressionSubtract, -780, 760)
wire(down, "", lean_r, "A")
wire(axis, "", lean_r, "B")
d_cm = node(unreal.MaterialExpressionMultiply, -780, 900, const_b=14.0)
wire(hang, "", d_cm, "A")
droop = node(unreal.MaterialExpressionMultiply, -620, 800)
wire(lean_r, "", droop, "A")
wire(d_cm, "", droop, "B")
stiff = node(
    unreal.MaterialExpressionMultiply, -480, 800, const_b=0.75
)  # soaked rag, not silk
wire(droop, "", stiff, "A")

# faint flutter so the hem never sits dead still
t2 = node(unreal.MaterialExpressionTime, -780, 1050)
fsin = node(unreal.MaterialExpressionSine, -620, 1050, period=0.8)
wire(t2, "", fsin, "")
f_amp = node(unreal.MaterialExpressionMultiply, -480, 1050, const_b=0.25)
wire(fsin, "", f_amp, "A")
f_hang = node(unreal.MaterialExpressionMultiply, -340, 1000)
wire(f_amp, "", f_hang, "A")
wire(hang, "", f_hang, "B")
zero2 = node(unreal.MaterialExpressionConstant, -340, 1120, r=0.0)
f_xy = node(unreal.MaterialExpressionAppendVector, -200, 1050)
wire(f_hang, "", f_xy, "A")
wire(zero2, "", f_xy, "B")
f_xyz = node(unreal.MaterialExpressionAppendVector, -80, 1050)
wire(f_xy, "", f_xyz, "A")
wire(zero2, "", f_xyz, "B")

wpo2 = node(unreal.MaterialExpressionAdd, -60, 900)
wire(stiff, "", wpo2, "A")
wire(f_xyz, "", wpo2, "B")

mma2 = node(unreal.MaterialExpressionMakeMaterialAttributes, 150, 400)
wire(cloth, "RGB", mma2, "BaseColor")
wire(rough, "", mma2, "Roughness")
wire(wpo2, "", mma2, "WorldPositionOffset")
mat.set_editor_property("use_material_attributes", True)
MEL.connect_material_property(mma2, "", unreal.MaterialProperty.MP_FRONT_MATERIAL)

unreal.log("PHASE: recompile rag")
MEL.recompile_material(mat)
EAL.save_asset(rag_path)
unreal.log("material built: " + rag_path)
rag_mat_asset = mat

# --- assign to the mesh slots ---
sk_path = f"{PLUGIN}/SK_MolotovBottle"
sk = EAL.load_asset(sk_path)
assert sk, "SK_MolotovBottle not found"
try:
    unreal.log(
        f"MESH has_vertex_colors = {sk.get_editor_property('has_vertex_colors')}"
    )
except Exception as e:  # noqa: BLE001
    unreal.log(f"MESH vertex color check unavailable: {e}")
targets = {"M_RagFlame": flame_mat_asset, "MI_molotov_rag": rag_mat_asset}
mats = list(sk.get_editor_property("materials"))
slot_names = [str(m.get_editor_property("material_slot_name")) for m in mats]
unreal.log(f"mesh slots: {slot_names}")
for m in mats:
    nm = str(m.get_editor_property("material_slot_name"))
    if nm in targets:
        m.set_editor_property("material_interface", targets.pop(nm))
if targets:
    unreal.log_error(f"missing slots {list(targets)} — reimport the FBX first!")
else:
    sk.set_editor_property("materials", mats)
    EAL.save_asset(sk_path)
    unreal.log("assigned M_RagFlame + MI_molotov_rag slots")
unreal.log("FLAME_MAT_DONE")
