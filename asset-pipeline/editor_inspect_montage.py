# Dump how the RGD5 throw montages are assembled. If the pin-pull is its own
# segment or section we can duplicate the montage and splice it out, keeping the
# bottle-friendly grip; if it is baked into one long sequence we have to borrow
# the bolt's pin-free motions instead. Read-only.
import unreal

MONTAGES = (
    "/Game/_STALKER2/Animations/Player/AnimSequences/grenades/RGD5/Throw/MG_fp_rgd5_strong_throw",
    "/Game/_STALKER2/Animations/Player/AnimSequences/grenades/RGD5/Throw/MG_fp_rgd5_one_hand_strong_throw",
    "/Game/_STALKER2/Animations/Player/AnimSequences/grenades/RGD5/Equip/MG_fp_rgd5_equip",
)


def prop(obj, name):
    try:
        return obj.get_editor_property(name)
    except Exception:
        return None


for path in MONTAGES:
    m = unreal.EditorAssetLibrary.load_asset(path)
    if not m:
        unreal.log_warning(f"MONTAGE MISSING {path}")
        continue
    unreal.log(f"MONTAGE {path}")
    unreal.log(f"MONTAGE   length={prop(m, 'sequence_length')}")

    for track in prop(m, "slot_anim_tracks") or []:
        slot = prop(track, "slot_name")
        anim_track = prop(track, "anim_track")
        segs = prop(anim_track, "anim_segments") if anim_track else None
        unreal.log(f"MONTAGE   slot={slot} segments={len(segs) if segs else 0}")
        for s in segs or []:
            ref = prop(s, "anim_reference")
            unreal.log(
                f"MONTAGE     seg {ref.get_name() if ref else None} "
                f"start={prop(s, 'start_pos')} "
                f"in={prop(s, 'anim_start_time')} out={prop(s, 'anim_end_time')}"
            )

    for sec in prop(m, "composite_sections") or []:
        unreal.log(
            f"MONTAGE   section {prop(sec, 'section_name')} "
            f"start={prop(sec, 'start_time')} next={prop(sec, 'next_section_name')}"
        )

    for n in prop(m, "notifies") or []:
        unreal.log(
            f"MONTAGE   notify {prop(n, 'notify_name')} at {prop(n, 'trigger_time_offset')}"
        )

unreal.log("MONTAGE_DONE")
