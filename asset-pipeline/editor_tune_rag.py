# Tune M_MolotovRag in place (no rebuild — preserves hand-wired FOV graph):
#   DroopStrength 3.5 -> 5.0   (heavier hang)
#   flutter speed 5.0 -> 1.8   (sin(Time*k): calm lick, not a gale)
#   flutter dir (0.25,0.25,0) -> (0.08,0.08,0)  (smaller sway amplitude)
# Run in editor:  py "<this file>"
import unreal

MAT = "/MolotovBottle/M_MolotovRag"
MEL = unreal.MaterialEditingLibrary
EAL = unreal.EditorAssetLibrary

mat = EAL.load_asset(MAT)
assert mat, "M_MolotovRag missing"
pkg = MAT.rsplit("/", 1)[0] + "/M_MolotovRag"


def subobjects(cls_name, limit=64):
    found = []
    for n in range(limit):
        o = unreal.load_object(None, f"{MAT}.M_MolotovRag:{cls_name}_{n}")
        if o:
            found.append(o)
    return found


changed = []

for e in subobjects("MaterialExpressionScalarParameter"):
    if str(e.get_editor_property("parameter_name")) == "DroopStrength":
        e.set_editor_property("default_value", 5.0)
        changed.append("DroopStrength -> 5.0")

for e in subobjects("MaterialExpressionConstant"):
    r = e.get_editor_property("r")
    if abs(r - 5.0) < 1e-4:
        e.set_editor_property("r", 1.8)
        changed.append("flutter speed 5.0 -> 1.8")

for e in subobjects("MaterialExpressionConstant3Vector"):
    c = e.get_editor_property("constant")
    if abs(c.r - 0.25) < 1e-4 and abs(c.g - 0.25) < 1e-4 and abs(c.b) < 1e-4:
        e.set_editor_property("constant", unreal.LinearColor(0.08, 0.08, 0.0, 0.0))
        changed.append("flutter dir -> (0.08, 0.08, 0)")

assert changed, "no matching expressions found — graph layout changed?"
for c in changed:
    unreal.log(f"TUNE: {c}")
MEL.recompile_material(mat)
EAL.save_asset(MAT)
unreal.log("RAG_TUNED saved")
