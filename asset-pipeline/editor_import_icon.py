# Import the built icons as UI Texture2Ds in the plugin. GameData cfgs resolve
# /MolotovBottle/... paths fine (the mesh prototypes already do), so the icons
# can live beside the meshes instead of needing a /Game slot.
# Run via editor_headless_all.py.
import os

import unreal

PLUGIN = "/MolotovBottle"
SRC = r"c:\Code\westerfield.cloud\Gaming\stalker-2\asset-pipeline\out"
NAMES = ("T_MolotovIcon", "T_MolotovKitIcon")


def import_icon(name):
    path = f"{PLUGIN}/{name}"
    task = unreal.AssetImportTask()
    task.set_editor_property("filename", os.path.join(SRC, name + ".png"))
    task.set_editor_property("destination_path", PLUGIN)
    task.set_editor_property("destination_name", name)
    task.set_editor_property("automated", True)
    task.set_editor_property("replace_existing", True)
    task.set_editor_property("save", True)
    unreal.AssetToolsHelpers.get_asset_tools().import_asset_tasks([task])

    tex = unreal.EditorAssetLibrary.load_asset(path)
    assert tex, f"icon import failed: {path}"

    # UI settings: no mips, no streaming, uncompressed - icons are small and
    # block compression shows badly on the flat label colours
    def _try(prop, value):
        try:
            tex.set_editor_property(prop, value)
        except Exception as exc:  # property names drift between engine versions
            unreal.log_warning(f"icon: could not set {prop} ({exc})")

    _try("srgb", True)
    _try(
        "compression_settings",
        getattr(
            unreal.TextureCompressionSettings,
            "TC_EDITOR_ICON",
            unreal.TextureCompressionSettings.TC_DEFAULT,
        ),
    )
    _try("lod_group", unreal.TextureGroup.TEXTUREGROUP_UI)
    _try("mip_gen_settings", unreal.TextureMipGenSettings.TMGS_NO_MIPMAPS)
    _try("never_stream", True)

    saved = unreal.EditorAssetLibrary.save_asset(path)
    unreal.log(f"ICON_IMPORT {name} saved={saved}")


for n in NAMES:
    import_icon(n)

unreal.log("ICON_IMPORT_DONE")
