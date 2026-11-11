#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <bcrypt.h>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include "TransferPolicy.h"

namespace {
using BuildMenu = void (__fastcall *)(void*, std::int32_t, std::uint32_t, void*);
constexpr std::uintptr_t InventoryVtable = 0x8CE7BE0;
constexpr std::uintptr_t BuildMenuRva = 0x59D71A;
constexpr std::uintptr_t BuildMenuSlot = 0x628;
constexpr std::uintptr_t ManagerRva = 0xA2C85F8;
constexpr std::uintptr_t ItemPoolRva = 0xA74B120;
constexpr unsigned char SupportedHash[] = {
    0x2B,0xD3,0xF1,0x15,0xB9,0x59,0xA8,0xEE,0xE7,0xE5,0xC4,0xB4,0x2B,0x01,0x42,0xDD,
    0x00,0x25,0xBD,0x43,0x7E,0x10,0x14,0xF9,0x2D,0xFC,0x60,0xB9,0xAF,0xEE,0x54,0x79
};
std::uintptr_t base;
BuildMenu original;
HANDLE logFile = INVALID_HANDLE_VALUE;
volatile LONG faulted;
std::uint32_t lastLoggedItem = 0xFFFFFFFF;

void Log(const char* message) {
    SYSTEMTIME time{};
    GetLocalTime(&time);
    char line[512]{};
    const int length = sprintf_s(line, "[%02u:%02u:%02u] %s\r\n",
        time.wHour, time.wMinute, time.wSecond, message);
    OutputDebugStringA(line);
    if (length > 0 && logFile != INVALID_HANDLE_VALUE) {
        DWORD written{};
        if (!WriteFile(logFile, line, static_cast<DWORD>(length), &written, nullptr) ||
            written != static_cast<DWORD>(length)) {
            OutputDebugStringA("ZoneStash: log write failed.\n");
        }
    }
}

bool SupportedImage(const wchar_t* path) {
    HANDLE file = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
        nullptr, OPEN_EXISTING, FILE_FLAG_SEQUENTIAL_SCAN, nullptr);
    if (file == INVALID_HANDLE_VALUE) return false;
    BCRYPT_ALG_HANDLE algorithm{};
    BCRYPT_HASH_HANDLE hash{};
    bool ok = BCryptOpenAlgorithmProvider(&algorithm, BCRYPT_SHA256_ALGORITHM, nullptr, 0) >= 0;
    if (ok) ok = BCryptCreateHash(algorithm, &hash, nullptr, 0, nullptr, 0, 0) >= 0;
    unsigned char buffer[65536];
    DWORD count{};
    while (ok) {
        if (!ReadFile(file, buffer, sizeof(buffer), &count, nullptr)) { ok = false; break; }
        if (!count) break;
        ok = BCryptHashData(hash, buffer, count, 0) >= 0;
    }
    unsigned char digest[32]{};
    if (ok) ok = BCryptFinishHash(hash, digest, sizeof(digest), 0) >= 0 &&
        std::memcmp(digest, SupportedHash, sizeof(digest)) == 0;
    if (hash) BCryptDestroyHash(hash);
    if (algorithm) BCryptCloseAlgorithmProvider(algorithm, 0);
    CloseHandle(file);
    return ok;
}

template<class T> T Read(std::uintptr_t address) {
    T value;
    std::memcpy(&value, reinterpret_cast<const void*>(address), sizeof(value));
    return value;
}

// These layouts were checked against the exact hashed Steam 2.1.0 executable and
// live personal-stash menus. Never use them on another build.
bool UpdateTransferRows(void* inventory, std::uint32_t uid, void* model) {
    const auto inv = reinterpret_cast<std::uintptr_t>(inventory);
    const auto rows = reinterpret_cast<std::uintptr_t>(model);
    if (rows != inv + 0xB70 || Read<std::uintptr_t>(inv) != base + InventoryVtable ||
        Read<std::uint32_t>(rows) != uid || (uid & 0xF8000000u) != 0x30000000u) return false;
    const auto storage = Read<std::uintptr_t>(inv + 0x6E0);
    const auto manager = Read<std::uintptr_t>(base + ManagerRva);
    if (!storage || !manager) return false;
    const auto stash = Read<std::uint32_t>(manager + 0x80);
    const auto open = Read<std::uint32_t>(storage + 8);
    const auto backpack = Read<std::uint32_t>(inv + 0x6B8);
    if (!ZoneStash::IsContainer(stash) || open != stash) return false;
    auto pool = base + ItemPoolRva;
    auto index = uid & 0x7FFFFFFu;
    while (index >= 0x1000u) {
        pool = Read<std::uintptr_t>(pool);
        if (!pool) return false;
        index -= 0x1000u;
    }
    const auto item = pool + 0x10 + static_cast<std::uintptr_t>(index) * 0x88;
    if (Read<std::uint32_t>(item + 8) != uid) return false;
    const auto owner = Read<std::uintptr_t>(item + 0x20);
    if (!owner) return false;
    const auto flags = Read<std::uint16_t>(item + 0x40);
    const ZoneStash::TransferContext context{
        stash, open, backpack, Read<std::uint32_t>(owner + 8),
        Read<std::int32_t>(item + 0x44), (flags & 0x200) != 0, (flags & 4) != 0
    };
    const auto transfer = ZoneStash::AllowedTransfer(context);
    if (transfer == ZoneStash::Transfer::None) return false;
    const unsigned int action = transfer == ZoneStash::Transfer::Deposit ? 17u : 1u;
    const auto row = rows + 0x20 + action * 0x38;
    if (Read<std::int32_t>(row + 0x18) != static_cast<std::int32_t>(action) ||
        Read<std::int32_t>(row + 0x38 + 0x18) != static_cast<std::int32_t>(action + 1)) {
        InterlockedExchange(&faulted, 1);
        Log("ERROR: unexpected menu action layout; further overrides disabled.");
        return false;
    }
    // Only menu visibility/enabled bytes change. Native transfer/stack handling,
    // quest flags, item identity, and all other actions are untouched.
    *reinterpret_cast<unsigned char*>(row) = 1;
    *reinterpret_cast<unsigned char*>(row + 1) = 1;
    if (context.quantity > 1) {
        *reinterpret_cast<unsigned char*>(row + 0x38) = 1;
        *reinterpret_cast<unsigned char*>(row + 0x39) = 1;
    }
    if (uid != lastLoggedItem) {
        char message[128]{};
        sprintf_s(message, "Allowed quest-item %s menu: item=%08X stash=%08X; quest flags unchanged.",
            transfer == ZoneStash::Transfer::Deposit ? "deposit" : "retrieval", uid, stash);
        Log(message);
        lastLoggedItem = uid;
    }
    return true;
}

void __fastcall OnBuildMenu(void* inventory, std::int32_t grid, std::uint32_t uid, void* model) {
    original(inventory, grid, uid, model);
    if (InterlockedCompareExchange(&faulted, 0, 0)) return;
    __try {
        UpdateTransferRows(inventory, uid, model);
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        InterlockedExchange(&faulted, 1);
        Log("ERROR: native menu inspection failed; further overrides disabled.");
    }
}

DWORD WINAPI Start(void* module) {
    wchar_t path[MAX_PATH]{};
    if (!GetModuleFileNameW(static_cast<HMODULE>(module), path, MAX_PATH) ||
        wcslen(path) >= MAX_PATH - 1) return 1;
    wchar_t* slash = wcsrchr(path, L'\\');
    if (!slash) return 1;
    wcscpy_s(slash + 1, MAX_PATH - static_cast<size_t>(slash + 1 - path), L"ZoneStash.log");
    logFile = CreateFileW(path, GENERIC_WRITE, FILE_SHARE_READ, nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (logFile == INVALID_HANDLE_VALUE) {
        OutputDebugStringA("ZoneStash: cannot open log; plugin disabled.\n");
        return 1;
    }
    Log("Starting restricted personal-stash context-menu prototype.");
    if (!GetModuleFileNameW(nullptr, path, MAX_PATH) || !SupportedImage(path)) {
        Log("DISABLED: executable unreadable or not the verified Steam 2.1.0 build; no hooks installed.");
        return 1;
    }
    base = reinterpret_cast<std::uintptr_t>(GetModuleHandleW(nullptr));
    auto slot = reinterpret_cast<void**>(base + InventoryVtable + BuildMenuSlot);
    if (*slot != reinterpret_cast<void*>(base + BuildMenuRva)) {
        Log("DISABLED: inventory vtable differs or another mod owns the slot; no hooks installed.");
        return 1;
    }
    HMODULE pinned{};
    if (!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_PIN,
            reinterpret_cast<LPCWSTR>(&OnBuildMenu), &pinned)) {
        Log("DISABLED: could not retain plugin for the process lifetime.");
        return 1;
    }
    original = reinterpret_cast<BuildMenu>(*slot);
    DWORD protection{};
    if (!VirtualProtect(slot, sizeof(void*), PAGE_READWRITE, &protection)) {
        Log("DISABLED: could not access inventory vtable.");
        return 1;
    }
    const auto prior = InterlockedCompareExchangePointer(slot, reinterpret_cast<void*>(&OnBuildMenu),
        reinterpret_cast<void*>(original));
    DWORD ignored{};
    const bool restored = VirtualProtect(slot, sizeof(void*), protection, &ignored) != FALSE;
    if (!restored) {
        InterlockedCompareExchangePointer(slot, reinterpret_cast<void*>(original), reinterpret_cast<void*>(&OnBuildMenu));
        if (!VirtualProtect(slot, sizeof(void*), protection, &ignored))
            Log("ERROR: vtable page protection still could not be restored.");
        Log("DISABLED: vtable page protection failed; our hook was rolled back.");
        return 1;
    }
    if (prior != reinterpret_cast<void*>(original)) {
        Log("DISABLED: inventory vtable changed during installation; existing hook preserved.");
        return 1;
    }
    Log("ACTIVE: personal-stash quest-item context menus enabled; gameplay verification required.");
    return 0;
}
}

BOOL WINAPI DllMain(HINSTANCE module, DWORD reason, LPVOID) {
    if (reason == DLL_PROCESS_ATTACH) {
        DisableThreadLibraryCalls(module);
        HANDLE thread = CreateThread(nullptr, 0, Start, module, 0, nullptr);
        if (!thread) return FALSE;
        CloseHandle(thread);
    }
    return TRUE;
}
