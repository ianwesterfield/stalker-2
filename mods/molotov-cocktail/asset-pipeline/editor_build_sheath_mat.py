# Build the fire materials M_RagFlame (cap cards) + M_SheathFlame (engulf
# shells) from ONE recipe modeled on the game's M_VFX_Fire_Cin_4 (the
# NS_Character_Fire sprite material the user prefers): T_VFX_FireWall_D 8x8
# flipbook, TRANSLUCENT+UNLIT with soft Power-eroded opacity, EyeAdaptation-
# stabilized emissive, dual-frame blend (Niagara SubUV smoothness), recolored
# blue roots -> texture-true body via vcA. Flipbook UVs are explicit node math.
# Runs in the headless driver every build (delete+recreate = fresh DDC key).
import unreal

PLUGIN = "/MolotovBottle"
GAME_FIRE_TEX = "/Game/_Stalker_2/VFX/Cinematic/E06_MQ02/T_VFX_FireWall_D"
# plugin-local copy: the mod cook strips cross-pak /Game texture refs (sampled
# black in-game), so we ship our own
FIRE_TEX = f"{PLUGIN}/T_VFX_FireWall_D"
MEL = unreal.MaterialEditingLibrary
EAL = unreal.EditorAssetLibrary

unreal.AssetRegistryHelpers.get_asset_registry().scan_paths_synchronous(
    [PLUGIN, "/Game/_Stalker_2/VFX/Cinematic/E06_MQ02"], force_rescan=True
)
assert EAL.does_directory_exist(f"{PLUGIN}/"), "plugin not mounted — junction first"

if not EAL.does_asset_exist(FIRE_TEX):
    unreal.log("PHASE: duplicate firewall texture into plugin")
    assert EAL.duplicate_asset(GAME_FIRE_TEX, FIRE_TEX), "texture duplicate failed"
    assert EAL.save_asset(FIRE_TEX, only_if_is_dirty=False)
t_fire = EAL.load_asset(FIRE_TEX)
assert t_fire, "firewall flipbook texture missing"


def build_fire_mat(name):
    mat_path = f"{PLUGIN}/{name}"
    if EAL.does_asset_exist(mat_path):
        unreal.log(f"PHASE: delete old {name}")
        EAL.delete_asset(mat_path)
    unreal.log(f"PHASE: create {name}")
    mat = unreal.AssetToolsHelpers.get_asset_tools().create_asset(
        name, PLUGIN, unreal.Material, unreal.MaterialFactoryNew()
    )
    assert mat, "material create failed"
    mat.set_editor_property("blend_mode", unreal.BlendMode.BLEND_TRANSLUCENT)
    mat.set_editor_property("shading_model", unreal.MaterialShadingModel.MSM_UNLIT)
    mat.set_editor_property("two_sided", True)
    # headless builds never render the mesh, so the usage flag never auto-sets ->
    # cook ships no skeletal permutation -> game silently uses the default material
    mat.set_editor_property("used_with_skeletal_mesh", True)

    def node(cls, x, y, **props):
        e = MEL.create_material_expression(mat, cls, x, y)
        for k, v in props.items():
            e.set_editor_property(k, v)
        return e

    def wire(src, out, dst, pin):
        assert MEL.connect_material_expressions(
            src, out, dst, pin
        ), f"{out}->{pin} failed"

    def scalar_param(name2, default, x, y):
        p = node(unreal.MaterialExpressionScalarParameter, x, y)
        p.set_editor_property("parameter_name", name2)
        p.set_editor_property("default_value", default)
        return p

    unreal.log("PHASE: build graph")
    uv = node(unreal.MaterialExpressionTextureCoordinate, -2300, 0)

    # A: flipbook frames — phase = Time*FPS; blend adjacent frames by frac(phase)
    # (the SubUV smoothness that makes the Niagara fire read liquid, not steppy)
    fps = scalar_param("FlipbookFPS", 18.0, -2300, -400)
    t = node(unreal.MaterialExpressionTime, -2300, -250)
    phase = node(unreal.MaterialExpressionMultiply, -2150, -330)
    wire(t, "", phase, "A")
    wire(fps, "", phase, "B")
    frame_f = node(unreal.MaterialExpressionFloor, -2000, -330)
    wire(phase, "", frame_f, "")
    blend = node(unreal.MaterialExpressionSubtract, -2000, -480)
    wire(phase, "", blend, "A")
    wire(frame_f, "", blend, "B")
    c64 = node(unreal.MaterialExpressionConstant, -2000, -200, r=64.0)
    c8 = node(unreal.MaterialExpressionConstant, -2000, -120, r=8.0)
    uv_cell = node(unreal.MaterialExpressionMultiply, -1250, -150, const_b=0.125)
    wire(uv, "", uv_cell, "A")

    def frame_uv(frame_src, ybase):
        frame = node(unreal.MaterialExpressionFmod, -1850, ybase)
        wire(frame_src, "", frame, "A")
        wire(c64, "", frame, "B")
        col = node(unreal.MaterialExpressionFmod, -1700, ybase - 70)
        wire(frame, "", col, "A")
        wire(c8, "", col, "B")
        row_div = node(
            unreal.MaterialExpressionMultiply, -1700, ybase + 70, const_b=0.125
        )
        wire(frame, "", row_div, "A")
        row = node(unreal.MaterialExpressionFloor, -1550, ybase + 70)
        wire(row_div, "", row, "")
        col_off = node(
            unreal.MaterialExpressionMultiply, -1550, ybase - 70, const_b=0.125
        )
        wire(col, "", col_off, "A")
        row_off = node(
            unreal.MaterialExpressionMultiply, -1400, ybase + 70, const_b=0.125
        )
        wire(row, "", row_off, "A")
        cell = node(unreal.MaterialExpressionAppendVector, -1250, ybase)
        wire(col_off, "", cell, "A")
        wire(row_off, "", cell, "B")
        fuv = node(unreal.MaterialExpressionAdd, -1100, ybase)
        wire(uv_cell, "", fuv, "A")
        wire(cell, "", fuv, "B")
        return fuv

    uv_a = frame_uv(frame_f, -330)
    frame_n = node(unreal.MaterialExpressionAdd, -2000, 30, const_b=1.0)
    wire(frame_f, "", frame_n, "A")
    uv_b = frame_uv(frame_n, 30)

    def sample(fuv, y):
        s = node(
            unreal.MaterialExpressionTextureSample,
            -950,
            y,
            texture=t_fire,
            sampler_type=unreal.MaterialSamplerType.SAMPLERTYPE_COLOR,
        )
        wire(fuv, "", s, "UVs")
        return s

    s_a = sample(uv_a, -330)
    s_b = sample(uv_b, 30)
    rgb = node(unreal.MaterialExpressionLinearInterpolate, -780, -150)
    wire(s_a, "RGB", rgb, "A")
    wire(s_b, "RGB", rgb, "B")
    wire(blend, "", rgb, "Alpha")

    # B: luminance drives opacity erosion + the blue root tint
    desat = node(unreal.MaterialExpressionDesaturation, -620, -150)
    wire(rgb, "", desat, "")
    one_c = node(unreal.MaterialExpressionConstant, -780, -20, r=1.0)
    wire(one_c, "", desat, "Fraction")
    lum = node(
        unreal.MaterialExpressionComponentMask,
        -470,
        -150,
        r=True,
        g=False,
        b=False,
        a=False,
    )
    wire(desat, "", lum, "")

    # C: color — texture-true fire body, alcohol-blue roots; vcA ramps 0 at the
    # roots -> 1 up the flame (authored per-geometry in Blender). vcA MUST come
    # from the dedicated "A" output (masking the float3 "" output fails cook)
    vc = node(unreal.MaterialExpressionVertexColor, -750, 100)
    blue = node(
        unreal.MaterialExpressionConstant3Vector,
        -750,
        220,
        constant=unreal.LinearColor(0.15, 0.3, 1.0, 0.0),
    )
    blue_root = node(unreal.MaterialExpressionMultiply, -550, 150)
    wire(blue, "", blue_root, "A")
    wire(lum, "", blue_root, "B")
    color = node(unreal.MaterialExpressionLinearInterpolate, -400, 0)
    wire(blue_root, "", color, "A")
    wire(rgb, "", color, "B")
    wire(vc, "A", color, "Alpha")

    # D: emissive — plain intensity; NO EyeAdaptation multiply: UE5 pre-exposure
    # already scales emissive, doubling it crushed the fire black in dark scenes
    inten = scalar_param("FireIntensity", 5.0, -400, 160)
    bright = node(unreal.MaterialExpressionMultiply, -250, 0)
    wire(color, "", bright, "A")
    wire(inten, "", bright, "B")

    # E: opacity — Power-eroded flame body (soft tongues, the donor's trick),
    # seated with a short DepthFade so face-on fire over the cloth survives
    opow = scalar_param("OpacityPower", 1.6, -470, 320)
    pw = node(unreal.MaterialExpressionPower, -300, 280)
    wire(lum, "", pw, "Base")
    wire(opow, "", pw, "Exp")
    # 0.0 = card flames fully invisible: Niagara NS_Character_Fire is the flame
    # visual now; the stacked translucent cards read as black silhouettes (video-
    # confirmed) — geometry/slots stay so flight-look MID code keeps working
    oboost = scalar_param("OpacityBoost", 0.0, -300, 420)
    op_raw = node(unreal.MaterialExpressionMultiply, -160, 320)
    wire(pw, "", op_raw, "A")
    wire(oboost, "", op_raw, "B")
    op_clamp = node(unreal.MaterialExpressionClamp, -40, 320)
    wire(op_raw, "", op_clamp, "")
    dfade = node(unreal.MaterialExpressionDepthFade, -160, 480, opacity_default=1.0)
    fade_d = scalar_param("FireDepthFade", 0.5, -360, 520)
    wire(fade_d, "", dfade, "FadeDistance")
    opacity = node(unreal.MaterialExpressionMultiply, 60, 380)
    wire(op_clamp, "", opacity, "A")
    wire(dfade, "", opacity, "B")

    # F: debug overlay — DebugUV=1 paints RG=geometry UV, B=luminance
    dbg_rg = node(unreal.MaterialExpressionAppendVector, -250, 620)
    mask_u = node(
        unreal.MaterialExpressionComponentMask,
        -450,
        580,
        r=True,
        g=False,
        b=False,
        a=False,
    )
    wire(uv, "", mask_u, "")
    mask_v = node(
        unreal.MaterialExpressionComponentMask,
        -450,
        670,
        r=False,
        g=True,
        b=False,
        a=False,
    )
    wire(uv, "", mask_v, "")
    wire(mask_u, "", dbg_rg, "A")
    wire(mask_v, "", dbg_rg, "B")
    dbg_rgb = node(unreal.MaterialExpressionAppendVector, -100, 640)
    wire(dbg_rg, "", dbg_rgb, "A")
    dbg_b = node(unreal.MaterialExpressionMultiply, -250, 740, const_b=0.5)
    wire(lum, "", dbg_b, "A")
    wire(dbg_b, "", dbg_rgb, "B")
    dbg_sw = scalar_param("DebugUV", 0.0, -100, 760)
    emissive = node(unreal.MaterialExpressionLinearInterpolate, 80, 100)
    wire(bright, "", emissive, "A")
    wire(dbg_rgb, "", emissive, "B")
    wire(dbg_sw, "", emissive, "Alpha")

    # G: WPO — proven recipe: custom normals are the flame axis, (world-up -
    # VertexNormalWS) * height re-points the flame world-up; BendClamp keeps
    # the flight hook's taming knob. UE V=0 at the tip for BOTH geometries.
    mask_v2 = node(
        unreal.MaterialExpressionComponentMask,
        -1000,
        900,
        r=False,
        g=True,
        b=False,
        a=False,
    )
    wire(uv, "", mask_v2, "")
    tipness = node(unreal.MaterialExpressionOneMinus, -850, 900)
    wire(mask_v2, "", tipness, "")
    vnorm = node(unreal.MaterialExpressionVertexNormalWS, -1000, 1050)
    world_up = node(
        unreal.MaterialExpressionConstant3Vector,
        -1000,
        1200,
        constant=unreal.LinearColor(0.0, 0.0, 1.0, 0.0),
    )
    lean = node(unreal.MaterialExpressionSubtract, -820, 1100)
    wire(world_up, "", lean, "A")
    wire(vnorm, "", lean, "B")
    height_cm = node(unreal.MaterialExpressionMultiply, -820, 1280, const_b=12.0)
    wire(tipness, "", height_cm, "A")
    bend = node(unreal.MaterialExpressionMultiply, -640, 1150)
    wire(lean, "", bend, "A")
    wire(height_cm, "", bend, "B")
    bclamp = scalar_param("BendClamp", 0.75, -640, 1320)
    bneg = node(unreal.MaterialExpressionMultiply, -500, 1360, const_b=-1.0)
    wire(bclamp, "", bneg, "A")
    clamp = node(unreal.MaterialExpressionClamp, -460, 1180)
    wire(bend, "", clamp, "")
    wire(bclamp, "", clamp, "Max")
    wire(bneg, "", clamp, "Min")

    t2 = node(unreal.MaterialExpressionTime, -1000, 1450)
    sin_x = node(unreal.MaterialExpressionSine, -850, 1430, period=0.9)
    wire(t2, "", sin_x, "")
    sin_y = node(unreal.MaterialExpressionSine, -850, 1530, period=0.57)
    wire(t2, "", sin_y, "")
    sway_xy = node(unreal.MaterialExpressionAppendVector, -700, 1470)
    wire(sin_x, "", sway_xy, "A")
    wire(sin_y, "", sway_xy, "B")
    zero = node(unreal.MaterialExpressionConstant, -700, 1580, r=0.0)
    sway_3d = node(unreal.MaterialExpressionAppendVector, -560, 1490)
    wire(sway_xy, "", sway_3d, "A")
    wire(zero, "", sway_3d, "B")
    sway_amp = node(unreal.MaterialExpressionMultiply, -420, 1490, const_b=0.5)
    wire(sway_3d, "", sway_amp, "A")
    sway = node(unreal.MaterialExpressionMultiply, -280, 1440)
    wire(sway_amp, "", sway, "A")
    wire(tipness, "", sway, "B")
    wpo = node(unreal.MaterialExpressionAdd, -120, 1250)
    wire(clamp, "", wpo, "A")
    wire(sway, "", wpo, "B")

    # direct pins: MP_FRONT_MATERIAL is the Substrate input — this game doesn't
    # run Substrate, so everything wired through it compiled to defaults
    # (emissive black + opacity 1.0 = the opaque black cards)
    assert MEL.connect_material_property(
        emissive, "", unreal.MaterialProperty.MP_EMISSIVE_COLOR
    ), "emissive pin failed"
    assert MEL.connect_material_property(
        opacity, "", unreal.MaterialProperty.MP_OPACITY
    ), "opacity pin failed"
    # GSC's Python enum lacks MP_WORLD_POSITION_OFFSET; WPO sway is cosmetic
    # (cards ship invisible) so skip gracefully if no spelling matches
    wpo_pin = next(
        (
            getattr(unreal.MaterialProperty, n)
            for n in ("MP_WORLD_POSITION_OFFSET", "MP_WORLDPOSITIONOFFSET")
            if hasattr(unreal.MaterialProperty, n)
        ),
        None,
    )
    if wpo_pin is not None:
        assert MEL.connect_material_property(wpo, "", wpo_pin), "wpo pin failed"
    else:
        unreal.log_warning(
            "WPO pin not in MaterialProperty enum; available: "
            + ", ".join(n for n in dir(unreal.MaterialProperty) if n.startswith("MP_"))
        )

    unreal.log("PHASE: recompile")
    MEL.recompile_material(mat)
    unreal.log("PHASE: save")
    assert EAL.save_asset(mat_path, only_if_is_dirty=False)
    return mat_path


done_flame = build_fire_mat("M_RagFlame")
unreal.log("FLAME_MAT_DONE: " + done_flame)
done_sheath = build_fire_mat("M_SheathFlame")

# retire the bonfire flipbook — nothing samples it now; don't ship dead weight
OLD_TEX = f"{PLUGIN}/T_fire_v02_8x8"
if EAL.does_asset_exist(OLD_TEX):
    unreal.log("PHASE: delete retired bonfire texture")
    EAL.delete_asset(OLD_TEX)
unreal.log("SHEATH_MAT_DONE: " + done_sheath)
