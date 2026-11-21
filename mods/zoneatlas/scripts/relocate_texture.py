"""Move a legacy (to-legacy output) texture package to a unique /Game/ZoneAtlas path.

The rename is same-length, byte-for-byte: every occurrence of the old package path and
object name is overwritten in place, so no header offsets shift. The name-map hashes go
stale, but UE5 dummy-reads them and retoc recomputes the zen-side hashes on to-zen.

Usage: relocate_texture.py <src.uasset> <stage-root> <index>
Prints the new object path (/Game/ZoneAtlas/<dir>/<name>.<name>) on success.
"""
import os
import shutil
import sys
from pathlib import Path

PREFIX = "/Game/ZoneAtlas/"
PROJECT = "Stalker2"


def legacy_package_path(uasset: Path) -> str:
    """<proj>/Content/X -> /Game/X; <proj>/Plugins/.../<Plugin>/Content/X -> /<Plugin>/X."""
    parts = uasset.with_suffix("").parts
    idx = max(i for i, p in enumerate(parts) if p == "Content")
    mount = "Game" if parts[idx - 1] == PROJECT else parts[idx - 1]
    return f"/{mount}/" + "/".join(parts[idx + 1:])


def relocate(src: Path, stage: Path, index: int) -> str:
    old_pkg = legacy_package_path(src)
    old_name = src.stem
    tag = f"T_ZA{index:02d}_"
    if len(old_name) < len(tag) + 5:
        raise SystemExit(f"name too short to relocate: {old_name}")
    new_name = tag + "x" * (len(old_name) - len(tag) - 5) + "_UDIM"
    dir_len = len(old_pkg) - len(PREFIX) - 1 - len(old_name)
    dir_tag = f"V{index:02d}"
    if dir_len < len(dir_tag):
        raise SystemExit(f"package path too short to relocate: {old_pkg}")
    new_dir = dir_tag + "_" * (dir_len - len(dir_tag))
    new_pkg = f"{PREFIX}{new_dir}/{new_name}"
    assert len(new_pkg) == len(old_pkg) and len(new_name) == len(old_name)

    header = src.read_bytes()
    if b"Texture2D" not in header:
        raise SystemExit(f"{src.name} is not a Texture2D package; refusing to relocate")
    if old_pkg.encode() not in header:
        raise SystemExit(f"package path {old_pkg} not found in {src}")
    patched = header.replace(old_pkg.encode(), new_pkg.encode()).replace(old_name.encode(), new_name.encode())
    assert len(patched) == len(header) and old_name.encode() not in patched

    uexp = src.with_suffix(".uexp")
    if uexp.exists() and old_name.encode() in uexp.read_bytes():
        raise SystemExit(f"{uexp.name} embeds the old name; only header renames are supported")

    dst = stage / PROJECT / "Content" / "ZoneAtlas" / new_dir
    dst.mkdir(parents=True, exist_ok=True)
    (dst / f"{new_name}.uasset").write_bytes(patched)
    for ext in (".uexp", ".ubulk", ".uptnl"):
        part = src.with_suffix(ext)
        if not part.exists():
            continue
        out = dst / f"{new_name}{ext}"
        if out.exists():
            out.unlink()
        try:
            os.link(part, out)  # bulk is multi-GB; hardlink when on the same volume
        except OSError:
            shutil.copyfile(part, out)
    return f"{new_pkg}.{new_name}"


if __name__ == "__main__":
    if len(sys.argv) != 4:
        raise SystemExit(__doc__)
    print(relocate(Path(sys.argv[1]), Path(sys.argv[2]), int(sys.argv[3])))
