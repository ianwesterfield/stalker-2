# Import the static twin SM_MolotovBottle through Interchange with the same
# explicit pipeline as the SK (keep custom normals, MikkTSpace tangents,
# vertex colors REPLACE, never import FBX placeholder materials).
# Run in editor Output Log:  py "<this file>"   then editor_fix_sm.py
import unreal

PLUGIN = "/MolotovBottle"
FBX = r"c:\Code\westerfield.cloud\Gaming\stalker-2\asset-pipeline\out\SM_MolotovBottle.fbx"

pipeline = unreal.InterchangeGenericAssetsPipeline()
cmp = pipeline.get_editor_property("common_meshes_properties")
cmp.set_editor_property("recompute_normals", False)
cmp.set_editor_property("recompute_tangents", True)
cmp.set_editor_property("use_mikk_t_space", True)
cmp.set_editor_property(
    "vertex_color_import_option",
    unreal.InterchangeVertexColorImportOption.IVCIO_REPLACE,
)
matp = pipeline.get_editor_property("material_pipeline")
matp.set_editor_property("import_materials", False)
matp.get_editor_property("texture_pipeline").set_editor_property(
    "import_textures", False
)

mgr = unreal.InterchangeManager.get_interchange_manager_scripted()
sd = unreal.InterchangeManager.create_source_data(FBX)
params = unreal.ImportAssetParameters()
params.is_automated = True
params.override_pipelines = [unreal.SoftObjectPath(pipeline.get_path_name())]
mgr.import_asset(PLUGIN, sd, params)
unreal.log("SM_IMPORT_QUEUED - wait for import completed, then run editor_fix_sm.py")
