# Print the CodeView PDB signature (GUID+age+path) a PE was built against.
import struct, sys

d = open(sys.argv[1], "rb").read()
pe = struct.unpack_from("<I", d, 0x3C)[0]
magic = struct.unpack_from("<H", d, pe + 0x18)[0]
is64 = magic == 0x20B
# optional header: data dirs start at 0x70 (PE32+) / 0x60 (PE32); debug dir = index 6
ddir = pe + (0x70 if is64 else 0x60)
dd_rva, dd_sz = struct.unpack_from("<II", d, ddir + 6 * 8)
sec = pe + 0x18 + struct.unpack_from("<H", d, pe + 0x14)[0]
nsec = struct.unpack_from("<H", d, pe + 6)[0]


def rva2off(r):
    for i in range(nsec):
        o = sec + i * 0x28
        vs, va, rs, rp = struct.unpack_from("<IIII", d, o + 8)
        if va <= r < va + max(vs, rs):
            return rp + (r - va)


off = rva2off(dd_rva)
print(f"debug dir rva={dd_rva:#x} size={dd_sz} off={off}")
if not off:
    sys.exit(1)
for i in range(dd_sz // 28):
    ts, _vmaj, _vmin, typ, sz, rva, _ptr = struct.unpack_from(
        "<IIIIIII", d, off + i * 28
    )
    print(f"  entry {i}: type={typ} size={sz:#x} rva={rva:#x}")
    if typ == 2:  # CodeView
        co = rva2off(rva)
        sig = struct.unpack_from("<I", d, co)[0]
        if sig == 0x53445352:  # RSDS
            guid = d[co + 4 : co + 20].hex()
            age = struct.unpack_from("<I", d, co + 20)[0]
            name = d[co + 24 : co + sz].split(b"\0")[0].decode(errors="replace")
            print(f"    RSDS guid={guid} age={age} pdb={name}")
        else:
            print(f"    CodeView sig={hex(sig)}")
