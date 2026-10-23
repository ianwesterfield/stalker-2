# Visualize SK_MolotovBottle vertex colors: debug material on the rag slot.
# Tail should show RED gradient (hang weight) + GREEN on outer shell.
# All-white = colors lost on import. Run:  py "<this file>"
import unreal

PLUGIN = "/MolotovBottle"
lib = unreal.MaterialEditingLibrary

dbg_path = f"{PLUGIN}/M_VtxDebug"
if unreal.EditorAssetLibrary.does_asset_exist(dbg_path):
    unreal.EditorAssetLibrary.delete_asset(dbg_path)
tools = unreal.AssetToolsHelpers.get_asset_tools()
mat = tools.create_asset(
    "M_VtxDebug", PLUGIN, unreal.Material, unreal.MaterialFactoryNew()
)
mat.set_editor_property("two_sided", True)
mat.set_editor_property("shading_model", unreal.MaterialShadingModel.MSM_UNLIT)

vc = lib.create_material_expression(mat, unreal.MaterialExpressionVertexColor, -400, 0)
lib.connect_material_property(vc, "", unreal.MaterialProperty.MP_EMISSIVE_COLOR)
lib.recompile_material(mat)
unreal.EditorAssetLibrary.save_asset(dbg_path)

sk = unreal.EditorAssetLibrary.load_asset(f"{PLUGIN}/SK_MolotovBottle")
mats = sk.get_editor_property("materials")
new_mats = list(mats)
for i, sm in enumerate(new_mats):
    if str(sm.get_editor_property("material_slot_name")) == "MI_molotov_rag":
        new_mats[i] = unreal.SkeletalMaterial(
            material_interface=mat,
            material_slot_name=sm.get_editor_property("material_slot_name"),
        )
        unreal.log(f"DEBUG material on slot {i}")
sk.set_editor_property("materials", new_mats)
unreal.log(
    "VTXDEBUG_ON — look at the rag; revert by reassigning M_MolotovRag in the slot dropdown"
)
