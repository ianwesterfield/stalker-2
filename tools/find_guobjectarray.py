# Re-derive the GUObjectArray AOB after a game patch shifts register allocation.
#
# UE4SS ships a hand-written byte pattern per game build; GSC patches keep the code
# shape but reassign registers, so the literal pattern dies while the structure holds.
# This finds the site by structure instead.
#
# FUObjectArray (UE5):            FChunkedFixedUObjectArray at +0x10:
#   +0x10  ObjObjects.Objects       +0x00  Objects      (FUObjectItem**)
#   +0x24  ObjObjects.NumElements   +0x14  NumElements  (int32)
#
# Every inlined IndexToObject bounds-check emits a RIP-relative `cmp [NumElements], reg`
# followed by a RIP-relative `mov r64, [Objects]`. Both operands are absolute data
# addresses, so the pair is identifiable by the invariant:
#
#     target(cmp) == target(mov) + 0x14       ->  GUObjectArray = target(mov) - 0x10
#
# Registers, jump widths and the surrounding math may all change; that offset cannot.
#
# Usage: python tools/find_guobjectarray.py <Stalker2-Win64-Shipping.exe> [-o out.lua]

import argparse
import hashlib
import re
import struct
import sys

# ModRM bytes encoding RIP-relative addressing: mod=00, rm=101 -> (modrm & 0xC7) == 0x05
RIPREL = bytes(r << 3 | 0x05 for r in range(8))

CMP_LEN = 6  # 39 /r disp32      cmp [rip+disp32], r32
MOV_LEN = 7  # 48 8B /r disp32   mov r64, [rip+disp32]

NUMELEMENTS_FROM_OBJECTS = 0x14
OBJECTS_FROM_BASE = 0x10

# How far the mov may trail the cmp; the jle between them is 2 or 6 bytes.
MAX_GAP = 40


def parse_pe(data):
    e_lfanew = struct.unpack_from("<I", data, 0x3C)[0]
    if data[e_lfanew : e_lfanew + 4] != b"PE\0\0":
        sys.exit("not a PE image")
    coff = e_lfanew + 4
    num_sections, size_opt = (
        struct.unpack_from("<H", data, coff + 2)[0],
        struct.unpack_from("<H", data, coff + 16)[0],
    )
    opt = coff + 20
    if struct.unpack_from("<H", data, opt)[0] != 0x20B:
        sys.exit("expected PE32+ (64-bit) image")
    image_base = struct.unpack_from("<Q", data, opt + 24)[0]

    sections = []
    table = opt + size_opt
    for i in range(num_sections):
        off = table + i * 40
        name = data[off : off + 8].rstrip(b"\0").decode("latin1")
        vsize, vaddr, rawsize, rawptr = struct.unpack_from("<IIII", data, off + 8)
        chars = struct.unpack_from("<I", data, off + 36)[0]
        sections.append(
            dict(
                name=name,
                vaddr=vaddr,
                vsize=vsize,
                rawptr=rawptr,
                rawsize=rawsize,
                exec=bool(chars & 0x20000000),
            )
        )
    return image_base, sections


def off_to_rva(sections, off):
    for s in sections:
        if s["rawptr"] <= off < s["rawptr"] + s["rawsize"]:
            return s["vaddr"] + (off - s["rawptr"])
    return None


def section_of_rva(sections, rva):
    for s in sections:
        if s["vaddr"] <= rva < s["vaddr"] + max(s["vsize"], s["rawsize"]):
            return s
    return None


def rip_target(data, sections, off, instr_len):
    """Absolute RVA referenced by a RIP-relative instruction at file offset `off`."""
    rva = off_to_rva(sections, off)
    if rva is None:
        return None
    disp = struct.unpack_from("<i", data, off + instr_len - 4)[0]
    return rva + instr_len + disp


def find_candidates(data, sections):
    mov_re = re.compile(b"\x48\x8b[" + re.escape(RIPREL) + b"]", re.DOTALL)
    cmp_re = re.compile(b"\x39[" + re.escape(RIPREL) + b"]", re.DOTALL)

    hits = {}
    for s in sections:
        if not s["exec"]:
            continue
        start, end = s["rawptr"], s["rawptr"] + s["rawsize"]
        blob = data[start:end]

        for m in mov_re.finditer(blob):
            mov_off = start + m.start()
            objects = rip_target(data, sections, mov_off, MOV_LEN)
            if objects is None:
                continue
            target_sec = section_of_rva(sections, objects)
            if target_sec is None or target_sec["exec"]:
                continue  # Objects lives in writable data, never in .text

            window_lo = max(0, m.start() - MAX_GAP)
            for c in cmp_re.finditer(blob, window_lo, m.start()):
                cmp_off = start + c.start()
                if cmp_off + CMP_LEN > mov_off:
                    continue  # overlapping decode, not a real instruction pair
                num_elements = rip_target(data, sections, cmp_off, CMP_LEN)
                if num_elements != objects + NUMELEMENTS_FROM_OBJECTS:
                    continue
                base = objects - OBJECTS_FROM_BASE
                hits.setdefault(base, []).append((cmp_off, mov_off))
    return hits


def build_pattern(data, cmp_off, mov_off):
    """cmp .. mov, both displacements wildcarded.

    Deliberately stops at the mov. The bytes in between are the bounds jump and the
    index math, which hold no displacements beyond the jump target. Reaching further
    would mean length-decoding arbitrary x86: a naive byte-walk mistakes ModRM and
    immediate bytes for opcodes (`C1 E8 10`, shr eax,0x10, reads as a call rel32).
    """
    out = [f"{data[cmp_off]:02X}", f"{data[cmp_off + 1]:02X}", "?", "?", "?", "?"]
    i = cmp_off + CMP_LEN

    if data[i] == 0x0F and 0x80 <= data[i + 1] <= 0x8F:  # jcc rel32
        out += [f"{data[i]:02X}", f"{data[i + 1]:02X}", "?", "?", "?", "?"]
        i += 6
    elif 0x70 <= data[i] <= 0x7F:  # jcc rel8
        out += [f"{data[i]:02X}", "?"]
        i += 2

    while i < mov_off:  # movzx / register math
        out.append(f"{data[i]:02X}")
        i += 1

    out += [
        f"{data[mov_off]:02X}",
        f"{data[mov_off + 1]:02X}",
        f"{data[mov_off + 2]:02X}",
        "?",
        "?",
        "?",
        "?",
    ]
    return " ".join(out)


def resolve_all(data, sections, pattern, mov_delta):
    """Every base address the pattern's matches resolve to, with match counts.

    A pattern need not be unique to be correct -- it must be unambiguous. Many call
    sites share the same shape, and all of them point at the one real array.
    """
    rx = pattern_to_regex(pattern)
    bases = {}
    for s in sections:
        if not s["exec"]:
            continue
        start = s["rawptr"]
        blob = data[start : start + s["rawsize"]]
        for m in rx.finditer(blob):
            target = rip_target(data, sections, start + m.start() + mov_delta, MOV_LEN)
            if target is not None:
                b = target - OBJECTS_FROM_BASE
                bases[b] = bases.get(b, 0) + 1
    return bases


def pattern_to_regex(pattern):
    parts = []
    for tok in pattern.split():
        parts.append(b"." if tok == "?" else re.escape(bytes([int(tok, 16)])))
    return re.compile(b"".join(parts), re.DOTALL)


LUA = """-- {exe}
-- SHA-256: {sha}

function Register()
    return "{pattern}"
end

function OnMatchFound(MatchAddress)
    local MovInstruction = MatchAddress + 0x{mov_delta:X}
    local Displacement = DerefToInt32(MovInstruction + 0x3)
    if Displacement == nil then
        return 0
    end

    -- The MOV addresses FUObjectArray.ObjObjects, which starts at +0x10.
    return MovInstruction + 0x7 + Displacement - 0x10
end
"""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("exe")
    ap.add_argument(
        "-o", "--out", help="write a UE4SS_Signatures/GUObjectArray.lua here"
    )
    args = ap.parse_args()

    data = open(args.exe, "rb").read()
    sha = hashlib.sha256(data).hexdigest().upper()
    image_base, sections = parse_pe(data)
    print(f"image base 0x{image_base:x}   sha256 {sha}")

    hits = find_candidates(data, sections)
    if not hits:
        sys.exit(
            "no GUObjectArray candidates found - the struct layout may have changed"
        )

    # The real array is referenced from many inlined call sites; noise is referenced once.
    ranked = sorted(hits.items(), key=lambda kv: len(kv[1]), reverse=True)
    print(f"\n{len(ranked)} candidate base address(es):")
    for base, sites in ranked:
        print(
            f"  GUObjectArray RVA 0x{base:08x}  (default base VA 0x{image_base + base:x})  "
            f"{len(sites)} reference site(s)"
        )

    base, sites = ranked[0]
    if len(ranked) > 1 and len(sites) == len(ranked[1][1]):
        print(
            "\nWARNING: top candidates are equally referenced - inspect before trusting"
        )

    print(f"\nbuilding pattern from {len(sites)} site(s) at RVA 0x{base:08x}")
    for cmp_off, mov_off in sites:
        mov_delta = mov_off - cmp_off
        pattern = build_pattern(data, cmp_off, mov_off)
        resolved = resolve_all(data, sections, pattern, mov_delta)
        total = sum(resolved.values())
        print(
            f"  cmp@0x{off_to_rva(sections, cmp_off):08x} mov+0x{mov_delta:X}  "
            f"{len(pattern.split()):3d} bytes  {total:5d} match(es) -> "
            + ", ".join(f"0x{b:08x}" for b in sorted(resolved))
        )
        if set(resolved) == {base}:
            lua = LUA.format(
                exe=args.exe.replace("\\", "/").rsplit("/", 1)[-1],
                sha=sha,
                pattern=pattern,
                mov_delta=mov_delta,
            )
            print("\n" + lua)
            if args.out:
                open(args.out, "w", newline="\n").write(lua)
                print(f"wrote {args.out}")
            return
    sys.exit("no site resolved unambiguously - inspect the candidates by hand")


if __name__ == "__main__":
    main()
