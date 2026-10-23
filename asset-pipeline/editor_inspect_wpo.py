"""Read-only WPO chain inspector for M_MolotovRag / M_RagFlame.
Walks backward from the World Position Offset pin, printing each node's
class/name/desc, to verify hand-wiring without eyeballing the graph.

Run in Zone Kit Output Log (Cmd):
  py "C:\\Code\\westerfield.cloud\\Gaming\\stalker-2\\asset-pipeline\\editor_inspect_wpo.py"
"""

import unreal

PLUGIN = "/MolotovBottle"
OURS = ["M_MolotovRag", "M_RagFlame"]
MEL = unreal.MaterialEditingLibrary
MAX_DEPTH = 12


def describe(expr):
    cls = type(expr).__name__
    extra = []
    for prop in ("parameter_name", "desc"):
        try:
            v = expr.get_editor_property(prop)
            if v:
                extra.append(f"{prop}={v}")
        except Exception:
            pass
    if cls == "MaterialExpressionMaterialFunctionCall":
        try:
            fn = expr.get_editor_property("material_function")
            extra.append(f"fn={fn.get_name() if fn else None}")
        except Exception:
            pass
    return f"{cls}({', '.join(extra)})" if extra else cls


def walk(mat, expr, depth, seen):
    pad = "  " * depth
    if expr is None:
        unreal.log(f"[inspect] {pad}<none>")
        return
    key = expr.get_name()
    tag = " <CYCLE/SEEN>" if key in seen else ""
    unreal.log(f"[inspect] {pad}{describe(expr)}{tag}")
    if key in seen or depth >= MAX_DEPTH:
        return
    seen.add(key)
    try:
        inputs = MEL.get_inputs_for_material_expression(mat, expr)
    except Exception as e:
        unreal.log(f"[inspect] {pad}  (get_inputs failed: {e})")
        return
    for child in inputs:
        walk(mat, child, depth + 1, seen)


for name in OURS:
    mat = unreal.EditorAssetLibrary.load_asset(f"{PLUGIN}/{name}")
    unreal.log(f"[inspect] ===== {name} =====")
    root = None
    for prop_name in ("MP_WORLD_POSITION_OFFSET", "MP_WORLDPOSITIONOFFSET"):
        prop = getattr(unreal.MaterialProperty, prop_name, None)
        if prop is None:
            continue
        try:
            root = MEL.get_material_property_input_node(mat, prop)
            unreal.log(
                f"[inspect] WPO root via {prop_name}: {describe(root) if root else 'NOT CONNECTED'}"
            )
            break
        except Exception as e:
            unreal.log(f"[inspect] {prop_name} failed: {e}")
    if root:
        walk(mat, root, 1, set())

unreal.log("[inspect] done")
