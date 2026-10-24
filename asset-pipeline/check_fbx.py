# Headless check: does out/SK_MolotovBottle.fbx actually contain the hijacked
# flame normals and the rag vertex colors? Round-trips through Blender's FBX
# importer and reports.
import bpy
import sys
from mathutils import Vector

bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.fbx(
    filepath=r"c:\Code\westerfield.cloud\Gaming\stalker-2\asset-pipeline\out\SK_MolotovBottle.fbx"
)

meshes = [o for o in bpy.data.objects if o.type == "MESH"]
print(f"CHECK mesh objects: {[o.name for o in meshes]}")
ob = meshes[0]
me = ob.data
print(f"CHECK verts={len(me.vertices)} polys={len(me.polygons)}")
print(f"CHECK material slots: {[m.name if m else None for m in me.materials]}")

# color attribute
attrs = {a.name: (a.domain, a.data_type) for a in me.color_attributes}
print(f"CHECK color attributes: {attrs}")
if me.color_attributes:
    ca = me.color_attributes[0]
    vals = [tuple(round(c, 3) for c in d.color[:2]) for d in ca.data]
    r_nonzero = sum(1 for r, g in vals if r > 0.01)
    g_zero = sum(1 for r, g in vals if g < 0.5)
    print(f"CHECK color samples={len(vals)} R>0.01: {r_nonzero}  G<0.5: {g_zero}")
    print(f"CHECK R range: {min(v[0] for v in vals)} .. {max(v[0] for v in vals)}")
else:
    print("CHECK NO COLOR ATTRIBUTES — FBX lost them")

# flame custom normals: loops of polys using the flame material
for tag in ("RagFlame", "SheathFlame"):
    flame_idx = next(
        (i for i, m in enumerate(me.materials) if m and tag in m.name), None
    )
    print(f"CHECK {tag} material index: {flame_idx}")
    if flame_idx is not None:
        zs = []
        for p in me.polygons:
            if p.material_index == flame_idx:
                for li in p.loop_indices:
                    zs.append(me.loops[li].normal.z)
        if zs:
            print(
                f"CHECK {tag} loop normals: n={len(zs)} min_z={min(zs):.3f} max_z={max(zs):.3f}"
            )
        else:
            print(f"CHECK no {tag} polys found")
# static twin: helpers stripped, flame normals intact after the edit-mode delete
bpy.ops.import_scene.fbx(
    filepath=r"c:\Code\westerfield.cloud\Gaming\stalker-2\asset-pipeline\out\SM_MolotovBottle.fbx"
)
sm = next(o for o in bpy.data.objects if o.type == "MESH" and o.name.startswith("SM_"))
sme = sm.data
print(f"CHECK SM verts={len(sme.vertices)} polys={len(sme.polygons)}")
assert len(sme.vertices) == len(me.vertices) - 6, "phys helpers leaked into SM twin"
for tag in ("RagFlame", "SheathFlame"):
    fi = next((i for i, m in enumerate(sme.materials) if m and tag in m.name), None)
    zs = [
        sme.loops[li].normal.z
        for p in sme.polygons
        if p.material_index == fi
        for li in p.loop_indices
    ]
    print(f"CHECK SM {tag} loop normals: n={len(zs)} min_z={min(zs):.3f}")
    assert min(zs) > 0.99, f"SM {tag} custom normals lost in helper strip"
print("CHECK_DONE")
