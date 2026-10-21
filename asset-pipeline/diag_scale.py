import bpy

FILES = {
    "OURS": r"c:\Code\westerfield.cloud\Gaming\stalker-2\asset-pipeline\out\SK_MolotovBottle.fbx",
    "RGD5": r"c:\Code\westerfield.cloud\Gaming\stalker-2\asset-pipeline\ref\Game\_STALKER2\SkeletalMeshes\weapons\grenades\RGD5\SK_RGD5.FBX",
}

for label, path in FILES.items():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.fbx(filepath=path)
    for obj in bpy.data.objects:
        if obj.type == "ARMATURE":
            print(
                f"{label} ARM {obj.name} scale={tuple(round(s, 4) for s in obj.scale)}"
            )
            for b in obj.data.bones:
                if b.name in ("jnt_offset", "jnt_r_hand"):
                    head_w = obj.matrix_world @ b.head_local
                    print(
                        f"{label} BONE {b.name} head_world={tuple(round(v, 4) for v in head_w)} length={round(b.length, 5)}"
                    )
        elif obj.type == "MESH":
            print(
                f"{label} MESH {obj.name} dims={tuple(round(d, 4) for d in obj.dimensions)} scale={tuple(round(s, 4) for s in obj.scale)}"
            )
