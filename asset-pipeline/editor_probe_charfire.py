"""One-boot recon: what material + textures drive NS_Character_Fire's sprite
emitters? Pure /Game read, no junction needed. Prints [charfire] lines."""

import unreal

reg = unreal.AssetRegistryHelpers.get_asset_registry()
reg.scan_paths_synchronous(["/Game/_Stalker_2/VFX/Player"], force_rescan=True)

NS = "/Game/_Stalker_2/VFX/Player/NS_Character_Fire"
ns = unreal.EditorAssetLibrary.load_asset(NS)
assert ns, "NS_Character_Fire not found"
unreal.log(f"[charfire] loaded {ns.get_path_name()}")

pkg = unreal.load_package(NS)


def dump_material(mat, depth=0):
    pad = "  " * depth
    unreal.log(f"[charfire] {pad}MATERIAL {mat.get_path_name()} ({type(mat).__name__})")
    if isinstance(mat, unreal.MaterialInstance):
        try:
            parent = mat.get_editor_property("parent")
            if parent:
                dump_material(parent, depth + 1)
        except Exception as e:
            unreal.log(f"[charfire] {pad}parent FAIL {e}")
        try:
            for tp in mat.texture_parameter_values:
                unreal.log(
                    f"[charfire] {pad}texparam {tp.parameter_info.name} = "
                    f"{tp.parameter_value.get_path_name() if tp.parameter_value else None}"
                )
            for sp in mat.scalar_parameter_values:
                unreal.log(
                    f"[charfire] {pad}scalar {sp.parameter_info.name} = {sp.parameter_value}"
                )
            for vp in mat.vector_parameter_values:
                v = vp.parameter_value
                unreal.log(
                    f"[charfire] {pad}vector {vp.parameter_info.name} = "
                    f"({v.r:.3f},{v.g:.3f},{v.b:.3f},{v.a:.3f})"
                )
        except Exception as e:
            unreal.log(f"[charfire] {pad}params FAIL {e}")
    elif isinstance(mat, unreal.Material):
        try:
            unreal.log(
                f"[charfire] {pad}base: blend={mat.get_editor_property('blend_mode')} "
                f"shading={mat.get_editor_property('shading_model')}"
            )
        except Exception as e:
            unreal.log(f"[charfire] {pad}props FAIL {e}")
        try:
            exprs = unreal.MaterialEditingLibrary.get_material_expressions(mat)
            counts = {}
            for ex in exprs:
                counts[type(ex).__name__] = counts.get(type(ex).__name__, 0) + 1
            unreal.log(f"[charfire] {pad}exprs: {counts}")
            for ex in exprs:
                if isinstance(ex, unreal.MaterialExpressionTextureBase):
                    tex = ex.get_editor_property("texture")
                    unreal.log(
                        f"[charfire] {pad}TEX {type(ex).__name__} -> "
                        f"{tex.get_path_name() if tex else None}"
                    )
        except Exception as e:
            unreal.log(f"[charfire] {pad}exprs FAIL {e}")


seen = set()
# renderer properties are package subobjects; walk them straight off the package
for i, obj in enumerate(unreal.ObjectIterator()):
    try:
        if obj.get_outermost() != pkg:
            continue
    except Exception:
        continue
    cn = type(obj).__name__
    if "RendererProperties" not in cn:
        continue
    unreal.log(f"[charfire] RENDERER {obj.get_path_name()} ({cn})")
    for prop in ("material", "sub_image_size", "alignment", "facing_mode", "sort_mode"):
        try:
            v = obj.get_editor_property(prop)
            unreal.log(f"[charfire]   {prop} = {v}")
            if prop == "material" and v and v.get_path_name() not in seen:
                seen.add(v.get_path_name())
                dump_material(v, 1)
        except Exception as e:
            unreal.log(f"[charfire]   {prop} FAIL {e}")

unreal.log("[charfire] DONE")
