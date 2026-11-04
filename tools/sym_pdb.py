# Resolve PE RVAs to nearest function symbols via dbghelp.
import ctypes, sys
from ctypes import wintypes

PDB = sys.argv[1]
MODULE = sys.argv[2]  # PE whose imagebase we emulate for the PDB
RVAS = [int(x, 16) for x in sys.argv[3:]]

ADDR = ctypes.c_ulonglong

dbghelp = ctypes.WinDLL(
    r"C:\Program Files (x86)\Windows Kits\10\Debuggers\x64\dbghelp.dll"
)
dbghelp.SymInitializeW.argtypes = [wintypes.HANDLE, wintypes.LPCWSTR, wintypes.BOOL]
dbghelp.SymLoadModuleExW.restype = ADDR
dbghelp.SymLoadModuleExW.argtypes = [
    wintypes.HANDLE,
    wintypes.HANDLE,
    wintypes.LPCWSTR,
    wintypes.LPCWSTR,
    ADDR,
    wintypes.DWORD,
    ctypes.c_void_p,
    wintypes.DWORD,
]
dbghelp.SymFromAddrW.argtypes = [
    wintypes.HANDLE,
    ADDR,
    ctypes.POINTER(ADDR),
    ctypes.c_void_p,
]
dbghelp.SymUnloadModule64.argtypes = [wintypes.HANDLE, ADDR]


class SYMBOL_INFO(ctypes.Structure):
    _fields_ = [
        ("SizeOfStruct", wintypes.ULONG),
        ("TypeIndex", wintypes.ULONG),
        ("Reserved", ADDR * 2),
        ("Index", wintypes.ULONG),
        ("Size", wintypes.ULONG),
        ("ModBase", ADDR),
        ("Flags", wintypes.ULONG),
        ("Value", ADDR),
        ("Address", ADDR),
        ("Register", wintypes.ULONG),
        ("Scope", wintypes.ULONG),
        ("Tag", wintypes.ULONG),
        ("NameLen", wintypes.ULONG),
        ("MaxNameLen", wintypes.ULONG),
        ("Name", wintypes.CHAR * 1024),
    ]


hProc = ctypes.cast(-1, wintypes.HANDLE)
dbghelp.SymInitializeW(hProc, None, False)

# find image size from the PE headers so SymLoadModuleEx covers the whole image
import struct

with open(MODULE, "rb") as f:
    data = f.read()
peoff = struct.unpack_from("<I", data, 0x3C)[0]
size_img = struct.unpack_from("<I", data, peoff + 0x50)[0]
BASE = ADDR(0x140000000)  # arbitrary 64-bit base for offset math

hMod = dbghelp.SymLoadModuleExW(hProc, None, PDB, None, BASE, size_img, None, 0)
if not hMod:
    print("SymLoadModuleEx failed:", ctypes.GetLastError())
    sys.exit(1)

for rva in RVAS:
    addr = ADDR(BASE.value + rva)
    sym = SYMBOL_INFO()
    sym.SizeOfStruct = ctypes.sizeof(SYMBOL_INFO)
    sym.MaxNameLen = 1024
    disp = ADDR(0)
    ok = dbghelp.SymFromAddrW(hProc, addr, ctypes.byref(disp), ctypes.byref(sym))
    if ok:
        print(f"+{rva:x} -> {sym.Name.decode(errors='replace')} +0x{disp.value:x}")
    else:
        print(f"+{rva:x} -> <no symbol>")

dbghelp.SymUnloadModule64(hProc, BASE)
