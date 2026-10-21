# Blender headless: inspect exported glbs (skeleton + skinning reference)
# Run: blender -b -P inspect_meshes.py
import bpy
import os

EXPORTS = r"C:\Tools\FModel\Output\Exports"
TARGETS = [
    (
        r"Stalker2\Content\_STALKER2\SkeletalMeshes\weapons\grenades\RGD5\SK_RGD5.glb",
        "SK_RGD5",
    ),
    (
        r"Stalker2\Mods\ZoneGrenades\Content\Meshes\SK_ZoneGrenadeBottle.glb",
        "SK_ZoneGrenadeBottle",
    ),
    (
        r"Stalker2\Content\_Stalker_2\items\consumable\SM_cns_cossacks_vodka_01_c.glb",
        "SM_cossacks_vodka",
    ),
]


def clear_scene():
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete()
    for block in (
        bpy.data.meshes,
        bpy.data.armatures,
        bpy.data.materials,
        bpy.data.images,
    ):
        for item in list(block):
            if item.users == 0:
                block.remove(item)


def dump_armature(obj):
    arm = obj.data
    print(f"  armature '{obj.name}': {len(arm.bones)} bones")

    def walk(bone, depth):
        h = bone.head_local
        print(f"    {'  ' * depth}{bone.name}  head=({h.x:.2f},{h.y:.2f},{h.z:.2f})")
        for c in bone.children:
            walk(c, depth + 1)

    for root in [b for b in arm.bones if b.parent is None]:
        walk(root, 0)


def dump_mesh(obj):
    me = obj.data
    print(f"  mesh '{obj.name}': {len(me.vertices)} verts, {len(me.polygons)} polys")
    print(f"    materials: {[m.name if m else None for m in me.materials]}")
    dims = obj.dimensions
    print(f"    dimensions: ({dims.x:.2f}, {dims.y:.2f}, {dims.z:.2f})")
    if obj.vertex_groups:
        counts = {}
        weights = {}
        for v in me.vertices:
            for g in v.groups:
                name = obj.vertex_groups[g.group].name
                counts[name] = counts.get(name, 0) + 1
                weights.setdefault(name, []).append(g.weight)
        for name, n in sorted(counts.items(), key=lambda kv: -kv[1]):
            w = weights[name]
            print(
                f"    vgroup '{name}': {n} verts, weight min={min(w):.3f} max={max(w):.3f}"
            )
    else:
        print("    (no vertex groups)")


for rel, label in TARGETS:
    path = os.path.join(EXPORTS, rel)
    print(f"\n=== {label} ===")
    if not os.path.exists(path):
        print(f"  MISSING: {path}")
        continue
    clear_scene()
    bpy.ops.import_scene.gltf(filepath=path)
    for obj in bpy.context.scene.objects:
        if obj.type == "ARMATURE":
            dump_armature(obj)
    for obj in bpy.context.scene.objects:
        if obj.type == "MESH":
            dump_mesh(obj)

print("\ndone")
