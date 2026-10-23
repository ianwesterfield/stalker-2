# Reimport SK_MolotovBottle through Interchange with an EXPLICIT pipeline:
# the project default recomputes normals (kills the flame's hijacked
# flame-axis normals) and ignores vertex colors (droop weights -> white ->
# the rag explodes). Run in the editor Output Log:  py "<this file>"
import unreal

PLUGIN = "/MolotovBottle"
FBX = r"c:\Code\westerfield.cloud\Gaming\stalker-2\asset-pipeline\out\SK_MolotovBottle.fbx"

sk_path = f"{PLUGIN}/SK_MolotovBottle"
sk = unreal.EditorAssetLibrary.load_asset(sk_path)
assert sk, "SK_MolotovBottle missing"
skeleton = sk.get_editor_property("skeleton")
unreal.log(f"existing skeleton: {skeleton.get_path_name() if skeleton else None}")

pipeline = unreal.InterchangeGenericAssetsPipeline()
cmp = pipeline.get_editor_property("common_meshes_properties")
cmp.set_editor_property("recompute_normals", False)
# tangents MUST be recomputed (MikkTSpace): the FBX carries none and the rag
# droop axis = VertexTangentWS — junk tangents shatter the tail into fragments
cmp.set_editor_property("recompute_tangents", True)
cmp.set_editor_property("use_mikk_t_space", True)
cmp.set_editor_property(
    "vertex_color_import_option",
    unreal.InterchangeVertexColorImportOption.IVCIO_REPLACE,
)
skel = pipeline.get_editor_property("common_skeletal_meshes_and_animations_properties")
skel.set_editor_property("skeleton", skeleton)
meshp = pipeline.get_editor_property("mesh_pipeline")
meshp.set_editor_property("create_physics_asset", False)
# FBX carries placeholder materials (incl. one literally named M_RagFlame) —
# never let the import create/stomp assets; slots keep their names regardless
matp = pipeline.get_editor_property("material_pipeline")
matp.set_editor_property("import_materials", False)
matp.get_editor_property("texture_pipeline").set_editor_property(
    "import_textures", False
)

mgr = unreal.InterchangeManager.get_interchange_manager_scripted()
sd = unreal.InterchangeManager.create_source_data(FBX)
params = unreal.ImportAssetParameters()
params.is_automated = True
params.reimport_asset = sk
# OverridePipelines is an array of SoftObjectPath, not objects
params.override_pipelines = [unreal.SoftObjectPath(pipeline.get_path_name())]
mgr.import_asset(PLUGIN, sd, params)
unreal.log("REIMPORT_QUEUED - watch for Interchange import completed")
