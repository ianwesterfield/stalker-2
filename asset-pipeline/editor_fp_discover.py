"""Discover how vanilla materials implement the first-person FOV warp.

Run in Zone Kit Output Log (Cmd):
  py "C:\\Code\\westerfield.cloud\\Gaming\\stalker-2\\asset-pipeline\\editor_fp_discover.py"
"""

import re
import unreal

PAT = re.compile(r"fov|first|viewmodel|in_?hands|inhand", re.I)

# 1) Material functions with FOV/first-person-ish names
ar = unreal.AssetRegistryHelpers.get_asset_registry()
f = unreal.ARFilter(
    class_paths=[unreal.TopLevelAssetPath("/Script/Engine", "MaterialFunction")],
    package_paths=["/Game/_Stalker_2"],
    recursive_paths=True,
)
hits = [str(a.package_name) for a in ar.get_assets(f) if PAT.search(str(a.asset_name))]
unreal.log(f"[fpdisc] MF candidates ({len(hits)}):")
for h in sorted(hits):
    unreal.log(f"[fpdisc]   {h}")

# 2) FOV/first-person expression classes exposed to Python
cls = [n for n in dir(unreal) if n.startswith("MaterialExpression") and PAT.search(n)]
unreal.log(f"[fpdisc] expression classes: {cls}")

# 3) Dump vanilla base graph, flag FOV-related expressions
mat = unreal.EditorAssetLibrary.load_asset(
    "/Game/_Stalker_2/Materials/Material_Glass/M_PBR_Glass_Emissive"
)
exprs = None
for getter in (
    lambda: mat.get_editor_property("expressions"),
    lambda: mat.get_editor_property("editor_only_data")
    .get_editor_property("expression_collection")
    .get_editor_property("expressions"),
):
    try:
        exprs = list(getter())
        break
    except Exception as e:
        unreal.log(f"[fpdisc] getter failed: {e}")

if exprs is None:
    unreal.log_warning("[fpdisc] could not enumerate expressions")
else:
    unreal.log(f"[fpdisc] {len(exprs)} expressions in M_PBR_Glass_Emissive:")
    counts = {}
    for e in exprs:
        cn = type(e).__name__
        counts[cn] = counts.get(cn, 0) + 1
        if isinstance(e, unreal.MaterialExpressionMaterialFunctionCall):
            fn = e.get_editor_property("material_function")
            unreal.log(f"[fpdisc]   MFCall -> {fn.get_path_name() if fn else None}")
        elif PAT.search(cn):
            unreal.log(f"[fpdisc]   FOV-ish node: {cn}")
    for cn in sorted(counts):
        unreal.log(f"[fpdisc]   {counts[cn]:3d}x {cn}")

unreal.log("[fpdisc] DONE")
