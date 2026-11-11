# Batch import of the English Zone port into the ZoneKit EnglishZone plugin, driven by the manifest
# from make-englishzone-batch-manifest.ps1. Phases run in dependency order: textures -> material
# instances -> static meshes. Run via -run=pythonscript (see run-import-englishzone-batch.ps1).
# Env: EZ_BATCH_MANIFEST (required), EZ_BATCH_PHASES (default all), EZ_BATCH_FILTER (regex on name).
# NOTE: unreal.log Display lines never surface in commandlet stdout; markers go through log_error.
import json
import os
import re
import sys

import unreal

MANIFEST = os.environ.get("EZ_BATCH_MANIFEST", "")
PHASES = [
    p.strip()
    for p in os.environ.get("EZ_BATCH_PHASES", "textures,materials,meshes").split(",")
    if p.strip()
]
FILTER = re.compile(os.environ.get("EZ_BATCH_FILTER", "") or ".*", re.IGNORECASE)


def mark(kind, msg):
    unreal.log_error("EZ_BATCH_%s %s" % (kind, msg))


if not MANIFEST or not os.path.isfile(MANIFEST):
    mark("FAIL", "EZ_BATCH_MANIFEST not set or missing: %s" % MANIFEST)
    sys.exit(1)
with open(MANIFEST, "r", encoding="utf-8-sig") as f:
    manifest = json.load(f)

asset_tools = unreal.AssetToolsHelpers.get_asset_tools()
eal = unreal.EditorAssetLibrary
mel = unreal.MaterialEditingLibrary
# StaticMeshEditorSubsystem only exists with GEditor, i.e. in the full editor (-ExecutePythonScript),
# NOT under -run=pythonscript (and constructing one by hand crashes).
sme = unreal.get_editor_subsystem(unreal.StaticMeshEditorSubsystem)
GUI = os.environ.get("EZ_BATCH_GUI") == "1"
GLOBAL = unreal.MaterialParameterAssociation.GLOBAL_PARAMETER
stats = {"ok": 0, "fail": 0, "warn": 0}


def _norm(n):
    return n.replace("_", "").casefold()


def enum_lookup(enum_type):
    out = {}
    for attr in dir(enum_type):
        try:
            val = getattr(enum_type, attr)
        except Exception:
            continue
        if isinstance(val, enum_type):
            out[_norm(attr)] = val
    return out


TEXTURE_GROUPS = enum_lookup(unreal.TextureGroup)
COMPRESSION = enum_lookup(unreal.TextureCompressionSettings)
TEX_FILTER = enum_lookup(unreal.TextureFilter)
TRACE_FLAGS = enum_lookup(unreal.CollisionTraceFlag)


def warn(name, msg):
    stats["warn"] += 1
    mark("WARN", "%s: %s" % (name, msg))


def set_props(name, obj, **props):
    for k, v in props.items():
        try:
            obj.set_editor_property(k, v)
        except Exception as ex:
            warn(name, "%s.%s: %s" % (type(obj).__name__, k, ex))


def load_required(path):
    a = unreal.load_asset(path)
    if a is None:
        raise RuntimeError("asset not found: %s" % path)
    return a


def save(asset):
    if not eal.save_loaded_asset(asset, only_if_is_dirty=False):
        raise RuntimeError("save failed")


def selected(entries):
    return [e for e in entries if FILTER.search(e["name"])]


def run_phase(label, entries, fn, gc_every):
    for i, e in enumerate(entries, 1):
        try:
            detail = fn(e)
            stats["ok"] += 1
            mark("OK", "%s %s/%s %s" % (label, e["dest"], e["name"], detail or ""))
        except Exception as ex:
            stats["fail"] += 1
            mark("FAIL", "%s %s: %s" % (label, e["name"], ex))
        if i % gc_every == 0:
            unreal.SystemLibrary.collect_garbage()
    unreal.SystemLibrary.collect_garbage()


# ------------------------------------------------------------------ textures
def import_texture(e):
    task = unreal.AssetImportTask()
    task.filename = e["png"]
    task.destination_path = e["dest"]
    task.destination_name = e["name"]
    task.automated = True
    task.replace_existing = True
    task.save = False
    asset_tools.import_asset_tasks([task])
    tex = load_required("%s/%s.%s" % (e["dest"], e["name"], e["name"]))

    s = e["settings"]
    tex.set_editor_property("srgb", bool(s.get("SRGB", True)))
    tex.set_editor_property(
        "virtual_texture_streaming", bool(s.get("VirtualTextureStreaming", False))
    )
    if s.get("LODGroup"):
        grp = TEXTURE_GROUPS.get(_norm(s["LODGroup"]))
        if grp is not None:
            tex.set_editor_property("lod_group", grp)
        else:
            # ZoneKit hides stock groups (World*, Character*) from Python: set, cast and even
            # read all fail. Keep the importer's pick (normal maps -> WorldNormalMap); verify cooked.
            warn(
                e["name"],
                "TextureGroup %s not settable from Python; kept importer default"
                % s["LODGroup"],
            )
    comp = s.get("CompressionSettings") or "TC_Default"
    cval = COMPRESSION.get(_norm(comp))
    if cval is None:
        raise RuntimeError("unknown compression %s" % comp)
    tex.set_editor_property("compression_settings", cval)
    if s.get("Filter") and _norm(s["Filter"]) in TEX_FILTER:
        tex.set_editor_property("filter", TEX_FILTER[_norm(s["Filter"])])
    # Exports are post-LODBias mips; keep bias 0 so in-game resolution matches vanilla.
    tex.set_editor_property("lod_bias", 0)
    if comp == "TC_Normalmap":
        tex.set_editor_property("flip_green_channel", False)
    save(tex)
    return comp


# ------------------------------------------------------------------ material instances
def _snake(n):
    return re.sub(r"(?<!^)(?=[A-Z])", "_", n).lower()


def import_material(e):
    name, dest = e["name"], e["dest"]
    path = "%s/%s" % (dest, name)
    if eal.does_asset_exist(path):
        mi = load_required("%s.%s" % (path, name))
        mel.clear_all_material_instance_parameters(mi)
    else:
        mi = asset_tools.create_asset(
            name,
            dest,
            unreal.MaterialInstanceConstant,
            unreal.MaterialInstanceConstantFactoryNew(),
        )
        if mi is None:
            raise RuntimeError("create_asset failed")
    mel.set_material_instance_parent(mi, load_required(e["parent"]))

    # The set_* return values are unreliable (always False in this engine); check parameter names
    # against the parent and read values back instead.
    have = {
        "switch": {str(n) for n in mel.get_static_switch_parameter_names(mi)},
        "scalar": {str(n) for n in mel.get_scalar_parameter_names(mi)},
        "vector": {str(n) for n in mel.get_vector_parameter_names(mi)},
        "texture": {str(n) for n in mel.get_texture_parameter_names(mi)},
    }
    missing, mismatch = [], []

    def known(kind, pname):
        if pname in have[kind]:
            return True
        missing.append("%s:%s" % (kind, pname))
        return False

    for sw in e["switches"]:
        if known("switch", sw["name"]):
            mel.set_material_instance_static_switch_parameter_value(
                mi, sw["name"], bool(sw["value"]), GLOBAL
            )
    for p in e["scalars"]:
        if known("scalar", p["name"]):
            mel.set_material_instance_scalar_parameter_value(
                mi, p["name"], float(p["value"]), GLOBAL
            )
    for p in e["vectors"]:
        if known("vector", p["name"]):
            r, g, b, a = p["value"]
            mel.set_material_instance_vector_parameter_value(
                mi, p["name"], unreal.LinearColor(r, g, b, a), GLOBAL
            )
    for p in e["textures"]:
        if known("texture", p["name"]):
            mel.set_material_instance_texture_parameter_value(
                mi, p["name"], load_required(p["value"]), GLOBAL
            )
    if missing:
        warn(name, "params not on parent: %s" % ", ".join(missing))

    mel.update_material_instance(mi)
    for sw in e["switches"]:
        if sw["name"] in have["switch"]:
            got = mel.get_material_instance_static_switch_parameter_value(
                mi, sw["name"], GLOBAL
            )
            if bool(got) != bool(sw["value"]):
                mismatch.append("switch:%s=%s" % (sw["name"], got))
    for p in e["scalars"]:
        if p["name"] in have["scalar"]:
            got = mel.get_material_instance_scalar_parameter_value(
                mi, p["name"], GLOBAL
            )
            if abs(got - float(p["value"])) > 1e-4:
                mismatch.append("scalar:%s=%s" % (p["name"], got))
    for p in e["vectors"]:
        if p["name"] in have["vector"]:
            got = mel.get_material_instance_vector_parameter_value(
                mi, p["name"], GLOBAL
            )
            if (
                max(
                    abs(x - y) for x, y in zip((got.r, got.g, got.b, got.a), p["value"])
                )
                > 1e-4
            ):
                mismatch.append("vector:%s" % p["name"])
    for p in e["textures"]:
        if p["name"] in have["texture"]:
            got = mel.get_material_instance_texture_parameter_value(
                mi, p["name"], GLOBAL
            )
            gp = got.get_path_name() if got else None
            if gp != p["value"]:
                mismatch.append("texture:%s=%s" % (p["name"], gp))
    if mismatch:
        raise RuntimeError("readback mismatch: %s" % ", ".join(mismatch))

    if e.get("overrides"):
        bpo = mi.get_editor_property("base_property_overrides")
        for k, v in e["overrides"].items():
            sk = _snake(k)
            set_props(name, bpo, **{"override_" + sk: True, sk: v})
        mi.set_editor_property("base_property_overrides", bpo)
        mel.update_material_instance(mi)

    save(mi)
    return "switches=%d scalars=%d vectors=%d textures=%d" % (
        len(e["switches"]),
        len(e["scalars"]),
        len(e["vectors"]),
        len(e["textures"]),
    )


# ------------------------------------------------------------------ static meshes
def import_mesh(e):
    name, dest = e["name"], e["dest"]
    if sme is None:
        raise RuntimeError(
            "StaticMeshEditorSubsystem unavailable (run in the full editor)"
        )
    pipeline = unreal.InterchangeGenericAssetsPipeline()
    cm = pipeline.get_editor_property("common_meshes_properties")
    set_props(
        name,
        cm,
        force_all_mesh_as_type=unreal.InterchangeForceMeshType.IFMT_STATIC_MESH,
        recompute_normals=False,
        recompute_tangents=False,
    )
    c = e["collision"]
    mp = pipeline.get_editor_property("mesh_pipeline")
    set_props(
        name,
        mp,
        import_static_meshes=True,
        # Defaults False here; UCX_ meshes only pair with the render mesh in a combined import.
        combine_static_meshes=True,
        build_nanite=bool(e["nanite"]),
        generate_lightmap_u_vs=False,
        src_lightmap_index=e["lmIndex"],
        dst_lightmap_index=e["lmIndex"],
        # Convex collision = the mod's exact hulls, carried in the GLB as UCX_<mesh>_NN meshes.
        collision=c["convex"] > 0,
        import_collision_according_to_mesh_name=True,
        create_physics_asset=False,
    )
    mat = pipeline.get_editor_property("material_pipeline")
    set_props(name, mat, import_materials=False)
    try:
        set_props(
            name, mat.get_editor_property("texture_pipeline"), import_textures=False
        )
    except Exception:
        pass
    override = unreal.InterchangePipelineStackOverride()
    override.add_pipeline(pipeline)

    # Reimport over an existing asset keeps its old body setup (collision); start fresh.
    existing = "%s/%s" % (dest, name)
    if eal.does_asset_exist(existing) and not eal.delete_asset(existing):
        raise RuntimeError("could not delete existing %s" % existing)

    task = unreal.AssetImportTask()
    task.filename = e["glb"]
    task.destination_path = dest
    task.destination_name = name
    task.automated = True
    task.replace_existing = True
    task.save = False
    task.options = override
    asset_tools.import_asset_tasks([task])
    sm = load_required("%s/%s.%s" % (dest, name, name))

    # Slots: the GLB carries only slots that own triangles, named by slot. Rebuild the full slot
    # list in the mod's order and repoint each section by name so slot indices match the mod.
    want = [s["slot"] for s in e["slots"]]
    imported = [
        str(m.get_editor_property("material_slot_name"))
        for m in sm.get_editor_property("static_materials")
    ]
    nsec = sm.get_num_sections(0)
    sec_names = [imported[sme.get_lod_material_slot(sm, 0, s)] for s in range(nsec)]
    for n in sec_names:
        if n not in want:
            raise RuntimeError("imported slot %r not in manifest %s" % (n, want))
    mats = []
    for s in e["slots"]:
        m = unreal.StaticMaterial()
        if s["material"]:
            m.set_editor_property("material_interface", load_required(s["material"]))
        m.set_editor_property("material_slot_name", s["slot"])
        try:
            m.set_editor_property("imported_material_slot_name", s["slot"])
        except Exception:
            pass
        mats.append(m)
    sm.set_editor_property("static_materials", mats)
    remapped = 0
    for sec, n in enumerate(sec_names):
        idx = want.index(n)
        if sme.get_lod_material_slot(sm, 0, sec) != idx:
            sme.set_lod_material_slot(sm, idx, 0, sec)
            remapped += 1

    set_props(
        name,
        sm,
        light_map_coordinate_index=e["lmIndex"],
        light_map_resolution=e["lmRes"],
    )
    for k, v in e.get("props", {}).items():
        if sm.get_editor_property(k) != v:
            set_props(name, sm, **{k: v})
    ns = sm.get_editor_property("nanite_settings")
    if ns.enabled != bool(e["nanite"]):
        ns.enabled = bool(e["nanite"])
        sm.set_editor_property("nanite_settings", ns)

    # Collision: convex hulls came in via the GLB's UCX_ meshes; boxes are added here.
    if c["box"] > 0:
        sme.remove_collisions(sm)
        for _ in range(int(c["box"])):
            sme.add_simple_collisions(sm, unreal.ScriptCollisionShapeType.BOX)
    # sme.get_simple_collision_count reports 0 for UCX-imported convex elems; read AggGeom directly.
    agg = sm.get_editor_property("body_setup").get_editor_property("agg_geom")
    ncvx = len(agg.get_editor_property("convex_elems"))
    nbox = len(agg.get_editor_property("box_elems"))
    ncoll = ncvx + nbox
    if (ncvx, nbox) != (int(c["convex"]), int(c["box"])):
        raise RuntimeError(
            "collision convex=%d box=%d != mod convex=%s box=%s"
            % (ncvx, nbox, c["convex"], c["box"])
        )
    if c.get("traceFlag"):
        flag = TRACE_FLAGS.get(_norm(c["traceFlag"]))
        if flag is None:
            warn(name, "unknown trace flag %s" % c["traceFlag"])
        else:
            body = sm.get_editor_property("body_setup")
            body.set_editor_property("collision_trace_flag", flag)

    save(sm)
    final = [
        str(m.get_editor_property("material_slot_name"))
        for m in sm.get_editor_property("static_materials")
    ]
    if final != want:
        raise RuntimeError("slot order after save %s != %s" % (final, want))
    return "slots=%d sections=%d remapped=%d nanite=%s collision=%d" % (
        len(want),
        nsec,
        remapped,
        ns.enabled,
        ncoll,
    )


try:
    if "textures" in PHASES:
        run_phase("texture", selected(manifest["textures"]), import_texture, 25)
    if "materials" in PHASES:
        run_phase("material", selected(manifest["materials"]), import_material, 25)
    if "meshes" in PHASES:
        run_phase("mesh", selected(manifest["meshes"]), import_mesh, 4)
    mark("DONE", "ok=%d fail=%d warn=%d" % (stats["ok"], stats["fail"], stats["warn"]))
except Exception as ex:
    mark("FAIL", "aborted: %r" % ex)
finally:
    if GUI:
        unreal.SystemLibrary.quit_editor()
if not GUI and stats["fail"]:
    sys.exit(1)
