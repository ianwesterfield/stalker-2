"""Dump NS_Character_Fire emitter HANDLE names (what SetEmitterEnable matches).
Pure /Game read, no junction. Prints [handles] lines."""

import unreal

reg = unreal.AssetRegistryHelpers.get_asset_registry()
reg.scan_paths_synchronous(["/Game/_Stalker_2/VFX/Player"], force_rescan=True)

NS = "/Game/_Stalker_2/VFX/Player/NS_Character_Fire"
ns = unreal.EditorAssetLibrary.load_asset(NS)
assert ns, "NS_Character_Fire not found"
unreal.log(f"[handles] loaded {ns.get_path_name()}")

handles = None
for prop in ("emitter_handles", "EmitterHandles"):
    try:
        handles = ns.get_editor_property(prop)
        break
    except Exception as e:
        unreal.log(f"[handles] prop {prop} FAIL {e}")

if handles is None:
    # EmitterHandles protected -> read the emitter objects inside the system pkg;
    # object name == handle name, unique_emitter_name == runtime binding name
    for obj in unreal.ObjectIterator():
        try:
            if not isinstance(obj, unreal.NiagaraEmitter):
                continue
            if "NS_Character_Fire" not in obj.get_path_name():
                continue
            uniq = "?"
            try:
                uniq = obj.get_editor_property("unique_emitter_name")
            except Exception:
                pass
            unreal.log(
                f"[handles] emitter obj={obj.get_name()} unique={uniq} path={obj.get_path_name()}"
            )
        except Exception:
            pass
    # renderer properties are outered to their emitter: name the material each renders
    for obj in unreal.ObjectIterator():
        try:
            if "NS_Character_Fire" not in obj.get_path_name():
                continue
            cls = type(obj).__name__
            if "RendererProperties" not in cls:
                continue
            mat = None
            for mp in ("material", "Material"):
                try:
                    mat = obj.get_editor_property(mp)
                    break
                except Exception:
                    pass
            unreal.log(
                f"[handles] renderer {cls} outer={obj.get_outer().get_name() if obj.get_outer() else '?'} "
                f"mat={mat.get_path_name() if mat else None} path={obj.get_path_name()}"
            )
        except Exception:
            pass
else:
    for i, h in enumerate(handles):
        name = "?"
        enabled = "?"
        for np in ("name", "Name", "id_name"):
            try:
                name = h.get_editor_property(np)
                break
            except Exception:
                pass
        for ep in ("enabled", "is_enabled"):
            try:
                enabled = h.get_editor_property(ep)
                break
            except Exception:
                pass
        unreal.log(f"[handles] {i}: name={name} enabled={enabled}")

unreal.log("[handles] HANDLES_DONE")
