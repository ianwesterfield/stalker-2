import bpy

FILES = {
    "OURS": r"C:\Tools\FModel\Output\Exports\S.T.A.L.K.E.R. 2 Heart of Chornobyl\Stalker2\Mods\MolotovBottle\Content\SK_MolotovBottle.glb",
    "ZG": r"C:\Tools\FModel\Output\Exports\Stalker2\Mods\ZoneGrenades\Content\Meshes\SK_ZoneGrenadeBottle.glb",
}

for label, path in FILES.items():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.gltf(filepath=path)
    for obj in bpy.data.objects:
        if obj.type == "ARMATURE":
            print(
                f"{label} ARM {obj.name} scale={tuple(round(s, 4) for s in obj.scale)}"
            )
            for b in obj.data.bones:
                hw = obj.matrix_world @ b.head_local
                print(
                    f"{label} BONE {b.name} head_world=({hw.x:.5f},{hw.y:.5f},{hw.z:.5f})"
                )
        elif obj.type == "MESH":
            dims = obj.dimensions
            mw = obj.matrix_world
            print(
                f"{label} MESH {obj.name} dims=({dims.x:.5f},{dims.y:.5f},{dims.z:.5f}) world_scale={tuple(round(v, 4) for v in mw.to_scale())}"
            )
            lo = [min((mw @ v.co)[i] for v in obj.data.vertices) for i in range(3)]
            hi = [max((mw @ v.co)[i] for v in obj.data.vertices) for i in range(3)]
            print(
                f"{label} MESH {obj.name} world_bbox lo=({lo[0]:.5f},{lo[1]:.5f},{lo[2]:.5f}) hi=({hi[0]:.5f},{hi[1]:.5f},{hi[2]:.5f})"
            )
            groups = {
                g.name
                for v in obj.data.vertices
                for g in [obj.vertex_groups[gw.group] for gw in v.groups]
            }
            print(f"{label} MESH {obj.name} weight_groups={sorted(groups)}")
