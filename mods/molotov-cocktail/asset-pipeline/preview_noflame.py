# Strip the flame-card faces (in memory only — blend untouched) so drape
# previews show the cloth. Chain before the renderer:
#   blender -b out/molotov_bottle.blend -P preview_noflame.py -P preview_render.py
import bpy
import bmesh

ob = bpy.data.objects["SK_MolotovBottle"]
idxs = {
    i
    for i, m in enumerate(ob.data.materials)
    if m and ("RagFlame" in m.name or "SheathFlame" in m.name)
}
bm = bmesh.new()
bm.from_mesh(ob.data)
doomed = [f for f in bm.faces if f.material_index in idxs]
for f in doomed:
    bm.faces.remove(f)
bm.to_mesh(ob.data)
bm.free()
print(f"stripped {len(doomed)} flame faces for preview")
