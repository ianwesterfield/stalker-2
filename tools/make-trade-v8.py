# v8: byte-surgical insert, line-based. Clone the leaf containing the anchor SID
# (or the first leaf if absent), rename to GrenadeMolotov, splice after. Everything
# else stays byte-identical to the decoded vanilla text.
import pathlib

root = pathlib.Path(__file__).resolve().parents[1]
jobs = [
    (root / "build" / "bartender-vanilla.txt",
     root / "mod/Stalker2/Content/GameLite/GameData/ItemGeneratorPrototypes/MolotovTradeStock.cfg",
     "Vodka"),
    (root / "build" / "trader-consumables-vanilla.txt",
     root / "mod/Stalker2/Content/GameLite/GameData/ItemGeneratorPrototypes/MolotovTraderPool.cfg",
     None),
]

for src, dst, anchor in jobs:
    lines = src.read_text(encoding="utf-8").splitlines(keepends=True)

    sid_at = None
    for i, ln in enumerate(lines):
        s = ln.strip()
        if anchor and s == f"ItemPrototypeSID = {anchor}":
            sid_at = i
            break
        if not anchor and s.startswith("ItemPrototypeSID = "):
            sid_at = i
            break
    if sid_at is None:
        raise SystemExit(f"no anchor leaf in {src.name}")

    # walk back to the "[N] : struct.begin" opening this leaf
    start = next(i for i in range(sid_at, -1, -1)
                 if lines[i].strip().endswith(": struct.begin") and lines[i].lstrip().startswith("["))
    indent = lines[start][: len(lines[start]) - len(lines[start].lstrip())]
    # walk forward to the matching struct.end at same indent
    end = next(i for i in range(sid_at, len(lines))
               if lines[i].rstrip("\r\n") == indent + "struct.end")

    block = lines[start:end + 1]
    old_sid = block[[i for i, l in enumerate(block) if "ItemPrototypeSID" in l][0]].split("=")[1].strip()
    max_idx = max(int(l.strip().split("]")[0][1:]) for l in lines
                  if l.strip().startswith("[") and l.strip().endswith(": struct.begin"))
    clone = [l.replace(f"ItemPrototypeSID = {old_sid}", "ItemPrototypeSID = GrenadeMolotov")
             for l in block]
    clone[0] = clone[0].replace(clone[0].strip().split(" ")[0], f"[{max_idx + 1}]", 1)

    out = lines[:end + 1] + clone + lines[end + 1:]
    dst.write_text("".join(out), encoding="utf-8", newline="")
    print(f"{dst.name}: cloned {old_sid} leaf ({len(block)} lines) as [{max_idx + 1}] GrenadeMolotov")
