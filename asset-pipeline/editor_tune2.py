# Tune pass 2, in place (preserves hand-wired FOV graphs):
#   M_MolotovRag:  flutter dir (0.08,0.08,0) -> (0.03,0.03,0)   (even less breeze)
#   M_RagFlame:    emissive = lerp(blue burn, orange chain, vertexColor.A)
#                  A=1 (main cap) keeps the orange; A=0 (wick cards) goes
#                  dim blue-violet — alcohol flame, almost invisible
# Run in editor:  py "<this file>"
import unreal

MEL = unreal.MaterialEditingLibrary
EAL = unreal.EditorAssetLibrary


def subobjects(mat_path, asset, cls_name, limit=96):
    found = []
    for n in range(limit):
        o = unreal.load_object(None, f"{mat_path}.{asset}:{cls_name}_{n}")
        if o:
            found.append(o)
    return found


# --- rag flutter ---
RAG = "/MolotovBottle/M_MolotovRag"
rag = EAL.load_asset(RAG)
assert rag, "M_MolotovRag missing"
hit = False
for e in subobjects(RAG, "M_MolotovRag", "MaterialExpressionConstant3Vector"):
    c = e.get_editor_property("constant")
    if abs(c.r - 0.08) < 1e-4 and abs(c.g - 0.08) < 1e-4 and abs(c.b) < 1e-4:
        e.set_editor_property("constant", unreal.LinearColor(0.03, 0.03, 0.0, 0.0))
        hit = True
assert hit, "flutter dir constant not found"
MEL.recompile_material(rag)
EAL.save_asset(RAG)
unreal.log("TUNE: rag flutter dir -> (0.03, 0.03, 0)")

# --- flame: sync with rag + tame in-flight bend ---
FLAME = "/MolotovBottle/M_RagFlame"
mat = EAL.load_asset(FLAME)
assert mat, "M_RagFlame missing"

# droop/flutter constants must mirror the rag's or the fire detaches from cloth
for e in subobjects(FLAME, "M_RagFlame", "MaterialExpressionScalarParameter"):
    if str(e.get_editor_property("parameter_name")) == "DroopStrength":
        e.set_editor_property("default_value", 5.0)
        unreal.log("TUNE: flame DroopStrength -> 5.0")
for e in subobjects(FLAME, "M_RagFlame", "MaterialExpressionConstant"):
    if abs(e.get_editor_property("r") - 5.0) < 1e-4:
        e.set_editor_property("r", 1.8)
        unreal.log("TUNE: flame flutter speed -> 1.8")
for e in subobjects(FLAME, "M_RagFlame", "MaterialExpressionConstant3Vector"):
    c = e.get_editor_property("constant")
    if abs(c.r - 0.25) < 1e-4 and abs(c.g - 0.25) < 1e-4 and abs(c.b) < 1e-4:
        e.set_editor_property("constant", unreal.LinearColor(0.03, 0.03, 0.0, 0.0))
        unreal.log("TUNE: flame flutter dir -> (0.03, 0.03, 0)")

# in-flight fix: gravity bend (up - normal) hits magnitude 2 when the thrown
# bottle tumbles inverted, flinging flame tips ~28cm off the mesh — clamp it;
# in-hand tilt stays under the cap so the candle-up look is unchanged
lean = None
for e in subobjects(FLAME, "M_RagFlame", "MaterialExpressionSubtract"):
    for inp in MEL.get_inputs_for_material_expression(mat, e):
        if inp and "VertexNormalWS" in inp.get_class().get_name():
            lean = e
            break
    if lean:
        break
assert lean, "gravity-bend Subtract (VertexNormalWS input) not found"
bend = None
for e in subobjects(FLAME, "M_RagFlame", "MaterialExpressionMultiply"):
    ins = MEL.get_inputs_for_material_expression(mat, e)
    if any(i is lean for i in ins):
        bend = e
        break
assert bend, "bend Multiply (lean input) not found"

# 'seated' = the Multiply feeding emissive, identified by its DepthFade input
seated = None
for e in subobjects(FLAME, "M_RagFlame", "MaterialExpressionMultiply"):
    for inp in MEL.get_inputs_for_material_expression(mat, e):
        if inp and "DepthFade" in inp.get_class().get_name():
            seated = e
            break
    if seated:
        break
assert seated, "seated multiply (DepthFade input) not found"

vcs = subobjects(FLAME, "M_RagFlame", "MaterialExpressionVertexColor")
assert vcs, "VertexColor node not found"
vc = vcs[0]


def node(cls, x, y, **props):
    e = MEL.create_material_expression(mat, cls, x, y)
    for k, v in props.items():
        e.set_editor_property(k, v)
    return e


def wire(src, out, dst, pin):
    assert MEL.connect_material_expressions(src, out, dst, pin), f"{out}->{pin} failed"


# ±0.75/axis: in-hand 45° tilt (≈0.71 max component) passes untouched,
# inverted tumble (z component = 2.0) gets capped
lean_clamp = node(
    unreal.MaterialExpressionClamp, -730, 700, min_default=-0.75, max_default=0.75
)
wire(lean, "", lean_clamp, "")
wire(lean_clamp, "", bend, "A")
unreal.log("TUNE: gravity bend clamped to +/-0.75")

# NOTE: VertexColor's "" output is RGB-only (float3) — masking A off it fails
# cook translation; use the node's dedicated "A" output pin instead
lum_w = node(
    unreal.MaterialExpressionConstant3Vector,
    420,
    620,
    constant=unreal.LinearColor(0.30, 0.59, 0.11, 0.0),
)
lum = node(unreal.MaterialExpressionDotProduct, 560, 560)
wire(seated, "", lum, "A")
wire(lum_w, "", lum, "B")
blue_c = node(
    unreal.MaterialExpressionConstant3Vector,
    560,
    680,
    constant=unreal.LinearColor(0.15, 0.3, 1.0, 0.0),
)
blue = node(unreal.MaterialExpressionMultiply, 700, 600)
wire(lum, "", blue, "A")
wire(blue_c, "", blue, "B")
# dim it: alcohol burn is barely there
blue_dim = node(unreal.MaterialExpressionMultiply, 820, 600, const_b=0.35)
wire(blue, "", blue_dim, "A")
tinted = node(unreal.MaterialExpressionLinearInterpolate, 960, 300)
wire(blue_dim, "", tinted, "A")
wire(seated, "", tinted, "B")
wire(vc, "A", tinted, "Alpha")
MEL.connect_material_property(tinted, "", unreal.MaterialProperty.MP_EMISSIVE_COLOR)
MEL.recompile_material(mat)
EAL.save_asset(FLAME)
unreal.log("TUNE: flame blue-burn lerp wired to emissive")
unreal.log("TUNE2_DONE")
