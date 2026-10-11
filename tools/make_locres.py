#!/usr/bin/env python3
"""Rebuild the mod's Game.locres: vanilla locres + rows from localization.<lang>.csv.

Usage: make_locres.py <vanilla_locres> <csv> <output_locres>

The game resolves item text by locres key (sid_items_<SID>_name/_description).
UnrealLocres import cannot ADD keys, so this uses pylocres to append entries
to a full copy of the vanilla file; the mod pak then overrides the whole file.
Regenerate after every game patch that changes localization.
"""

import csv
import sys
from pathlib import Path

from pylocres import LocresFile, Namespace, Entry


def main(vanilla: Path, csv_path: Path, out: Path) -> int:
    loc = LocresFile()
    loc.read(vanilla)

    namespaces = {ns.name: ns for ns in loc}
    rows = list(csv.DictReader(csv_path.open(encoding="utf-8-sig")))
    added = 0
    for row in rows:
        ns_name, key, text = row["namespace"], row["key"], row["text"]
        ns = namespaces.get(ns_name)
        if ns is None:
            ns = Namespace(ns_name)
            loc.add(ns)
            namespaces[ns_name] = ns
        # vanilla entries all carry SourceStringHash = 0; match that
        ns.add(Entry(key, text, 0))
        added += 1

    out.parent.mkdir(parents=True, exist_ok=True)
    loc.write(out)

    # verify roundtrip
    check = LocresFile()
    check.read(out)
    found = {e.key for ns in check for e in ns}
    missing = [r["key"] for r in rows if r["key"] not in found]
    if missing:
        print(f"FAILED: keys missing after write: {missing}")
        return 1
    print(f"OK: {added} entries added, output verified ({out})")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 4:
        print(__doc__)
        raise SystemExit(1)
    raise SystemExit(main(Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])))
