# Import the rendered kit icon as a UI Texture2D in the plugin. GameData cfgs
# resolve /MolotovBottle/... paths fine (the mesh prototypes already do), so the
# icon can live beside the meshes instead of needing a /Game slot.
# Run via editor_headless_all.py.
import unreal

PLUGIN = "/MolotovBottle"
NAME = "T_MolotovKitIcon"
PNG = r"c:\Code\westerfield.cloud\Gaming\stalker-2\asset-pipeline\out\T_MolotovKitIcon.png"
PATH = f"{PLUGIN}/{NAME}"

task = unreal.AssetImportTask()
task.set_editor_property("filename", PNG)
task.set_editor_property("destination_path", PLUGIN)
task.set_editor_property("destination_name", NAME)
task.set_editor_property("automated", True)
task.set_editor_property("replace_existing", True)
task.set_editor_property("save", True)
unreal.AssetToolsHelpers.get_asset_tools().import_asset_tasks([task])

tex = unreal.EditorAssetLibrary.load_asset(PATH)
assert tex, f"icon import failed: {PATH}"


# UI settings: no mips, no streaming, uncompressed — icons are tiny and any
# block compression shows on the flat label/rag colours
def _try(prop, value):
    try:
        tex.set_editor_property(prop, value)
    except Exception as exc:  # property name drift between engine versions
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

saved = unreal.EditorAssetLibrary.save_asset(PATH)
unreal.log(f"ICON_IMPORT_DONE saved={saved} path={PATH}")
