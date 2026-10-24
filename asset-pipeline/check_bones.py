import bpy

bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.fbx(
    filepath=r"c:\Code\westerfield.cloud\Gaming\stalker-2\asset-pipeline\out\SK_MolotovBottle.fbx"
)
for ob in bpy.data.objects:
    if ob.type == "ARMATURE":
        for b in ob.data.bones:
            print(
                f"BONECHECK {b.name} head={tuple(round(v,2) for v in b.head_local)} "
                f"tail={tuple(round(v,2) for v in b.tail_local)} "
                f"parent={b.parent.name if b.parent else None}"
            )
    if ob.type == "MESH":
        vgs = [vg.name for vg in ob.vertex_groups]
        print(f"BONECHECK mesh groups: {vgs}")
        counts = {vg.name: 0 for vg in ob.vertex_groups}
        idx2name = {vg.index: vg.name for vg in ob.vertex_groups}
        for v in ob.data.vertices:
            for g in v.groups:
                if g.weight > 0.5:
                    counts[idx2name[g.group]] += 1
        print(f"BONECHECK weight counts: {counts}")
print("BONECHECK_DONE")
