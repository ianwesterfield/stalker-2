# Headless probe 2: plugin mount via UE_ADDITIONAL_PLUGIN_PATHS + discover the
# real Interchange wait/sync API in this 5.5 build, then try the actual SK
# reimport and see if it completes before the commandlet exits.
import unreal

# commandlets skip the full asset registry scan — force one for the plugin
unreal.log(
    f"PROBE2 mount_exists={unreal.EditorAssetLibrary.does_directory_exist('/MolotovBottle/')}"
)
reg = unreal.AssetRegistryHelpers.get_asset_registry()
reg.scan_paths_synchronous(["/MolotovBottle"], force_rescan=True)
assets = unreal.EditorAssetLibrary.list_assets("/MolotovBottle", recursive=True)
unreal.log(f"PROBE2 assets={assets}")

sk = unreal.EditorAssetLibrary.load_asset("/MolotovBottle/SK_MolotovBottle")
unreal.log(f"PROBE2 plugin_mounted={sk is not None}")
if not sk:
    raise SystemExit("plugin did not mount - UE_ADDITIONAL_PLUGIN_PATHS missing?")

mgr = unreal.InterchangeManager.get_interchange_manager_scripted()
api = [m for m in dir(mgr) if "wait" in m or "task" in m or "sync" in m]
unreal.log(f"PROBE2 mgr_api={api}")
papi = [m for m in dir(unreal.ImportAssetParameters()) if not m.startswith("_")]
unreal.log(f"PROBE2 params_api={papi}")

# real reimport attempt (same pipeline as editor_reimport_sk.py)
pipeline = unreal.InterchangeGenericAssetsPipeline()
cmp = pipeline.get_editor_property("common_meshes_properties")
cmp.set_editor_property("recompute_normals", False)
cmp.set_editor_property("recompute_tangents", True)
cmp.set_editor_property("use_mikk_t_space", True)
cmp.set_editor_property(
    "vertex_color_import_option",
    unreal.InterchangeVertexColorImportOption.IVCIO_REPLACE,
)
skel = pipeline.get_editor_property("common_skeletal_meshes_and_animations_properties")
skel.set_editor_property("skeleton", sk.get_editor_property("skeleton"))
pipeline.get_editor_property("mesh_pipeline").set_editor_property(
    "create_physics_asset", False
)
matp = pipeline.get_editor_property("material_pipeline")
matp.set_editor_property("import_materials", False)
matp.get_editor_property("texture_pipeline").set_editor_property(
    "import_textures", False
)

FBX = r"c:\Code\westerfield.cloud\Gaming\stalker-2\asset-pipeline\out\SK_MolotovBottle.fbx"
sd = unreal.InterchangeManager.create_source_data(FBX)
params = unreal.ImportAssetParameters()
params.is_automated = True
params.reimport_asset = sk
params.override_pipelines = [unreal.SoftObjectPath(pipeline.get_path_name())]
ok = mgr.import_asset("/MolotovBottle", sd, params)
unreal.log(f"PROBE2 AFTER_IMPORT_CALL ok={ok}")

sk2 = unreal.EditorAssetLibrary.load_asset("/MolotovBottle/SK_MolotovBottle")
verts = 0
try:
    verts = unreal.EditorSkeletalMeshLibrary.get_num_verts(sk2, 0)
except Exception:
    try:
        sub = unreal.get_editor_subsystem(unreal.SkeletalMeshEditorSubsystem)
        verts = sub.get_num_verts(sk2, 0)
    except Exception as e:
        unreal.log_warning(f"PROBE2 vert count unavailable: {e}")
unreal.log(f"PROBE2 lod0_verts={verts}")
unreal.log("PROBE2_DONE")
