#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <bcrypt.h>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include "TransferPolicy.h"

namespace
{
    using BuildMenu = void(__fastcall *)(void *, std::int32_t, std::uint32_t, void *);
    constexpr std::uintptr_t InventoryVtable = 0x8CE7BE0;
    constexpr std::uintptr_t BuildMenuRva = 0x59D71A;
    constexpr std::uintptr_t BuildMenuSlot = 0x628;
    constexpr std::uintptr_t ManagerRva = 0xA2C85F8;
    constexpr std::uintptr_t ItemPoolRva = 0xA74B120;

    // These offsets apply only to the verified Steam 2.1.0 executable.
    namespace GameLayout
    {
        namespace Inventory
        {
            constexpr std::uintptr_t MenuModel = 0xB70;
            constexpr std::uintptr_t Storage = 0x6E0;
            constexpr std::uintptr_t BackpackId = 0x6B8;
        }

        namespace Storage
        {
            constexpr std::uintptr_t ContainerId = 0x8;
        }

        namespace Owner
        {
            constexpr std::uintptr_t ContainerId = 0x8;
        }

        namespace Manager
        {
            constexpr std::uintptr_t PersonalStashId = 0x80;
        }

        namespace Item
        {
            constexpr std::uint32_t TypeMask = 0xF8000000u;
            constexpr std::uint32_t TypeId = 0x30000000u;
            constexpr std::uint32_t IndexMask = 0x7FFFFFFu;
            constexpr std::uint32_t EntriesPerPool = 0x1000u;
            constexpr std::uintptr_t FirstEntry = 0x10;
            constexpr std::uintptr_t EntrySize = 0x88;
            constexpr std::uintptr_t Uid = 0x8;
            constexpr std::uintptr_t Owner = 0x20;
            constexpr std::uintptr_t Flags = 0x40;
            constexpr std::uintptr_t Quantity = 0x44;
            constexpr std::uint16_t ProtectedFlag = 0x200;
            constexpr std::uint16_t EquippedFlag = 0x4;
        }

        namespace Menu
        {
            constexpr std::uintptr_t FirstRow = 0x20;
            constexpr std::uintptr_t RowSize = 0x38;
            constexpr std::uintptr_t ActionId = 0x18;
            constexpr std::uintptr_t Visible = 0;
            constexpr std::uintptr_t Enabled = 1;
            constexpr unsigned int DepositAction = 17;
            constexpr unsigned int RetrieveAction = 1;
        }
    }

    constexpr unsigned char SupportedHash[] = {
        0x2B, 0xD3, 0xF1, 0x15, 0xB9, 0x59, 0xA8, 0xEE, 0xE7, 0xE5, 0xC4, 0xB4, 0x2B, 0x01, 0x42, 0xDD,
        0x00, 0x25, 0xBD, 0x43, 0x7E, 0x10, 0x14, 0xF9, 0x2D, 0xFC, 0x60, 0xB9, 0xAF, 0xEE, 0x54, 0x79};
    std::uintptr_t base;
    BuildMenu original;
    HANDLE logFile = INVALID_HANDLE_VALUE;
    volatile LONG faulted;
    std::uint32_t lastLoggedItem = 0xFFFFFFFF;

    void Log(const char *message)
    {
        SYSTEMTIME time{};
        GetLocalTime(&time);
        char line[512]{};
        const int length = sprintf_s(line, "[%02u:%02u:%02u] %s\r\n",
                                     time.wHour, time.wMinute, time.wSecond, message);
        OutputDebugStringA(line);

        if (length > 0 && logFile != INVALID_HANDLE_VALUE)
        {
            DWORD written{};

            if (!WriteFile(logFile, line, static_cast<DWORD>(length), &written, nullptr) ||
                written != static_cast<DWORD>(length))
            {
                OutputDebugStringA("QuestStash: log write failed.\n");
            }
        }
    }

    bool SupportedImage(const wchar_t *path)
    {
        HANDLE file = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                                  nullptr, OPEN_EXISTING, FILE_FLAG_SEQUENTIAL_SCAN, nullptr);

        if (file == INVALID_HANDLE_VALUE)
            return false;

        BCRYPT_ALG_HANDLE algorithm{};
        BCRYPT_HASH_HANDLE hash{};
        bool ok = BCryptOpenAlgorithmProvider(&algorithm, BCRYPT_SHA256_ALGORITHM, nullptr, 0) >= 0;

        if (ok)
            ok = BCryptCreateHash(algorithm, &hash, nullptr, 0, nullptr, 0, 0) >= 0;

        unsigned char buffer[65536];
        DWORD count{};

        while (ok)
        {
            if (!ReadFile(file, buffer, sizeof(buffer), &count, nullptr))
            {
                ok = false;
                break;
            }

            if (!count)
                break;

            ok = BCryptHashData(hash, buffer, count, 0) >= 0;
        }

        unsigned char digest[32]{};

        if (ok)
            ok = BCryptFinishHash(hash, digest, sizeof(digest), 0) >= 0 &&
                 std::memcmp(digest, SupportedHash, sizeof(digest)) == 0;

        if (hash)
            BCryptDestroyHash(hash);

        if (algorithm)
            BCryptCloseAlgorithmProvider(algorithm, 0);

        CloseHandle(file);
        return ok;
    }

    template <class T>
    T Read(std::uintptr_t address)
    {
        T value;
        std::memcpy(&value, reinterpret_cast<const void *>(address), sizeof(value));
        return value;
    }

    bool IsExpectedMenu(std::uintptr_t inventory, std::uintptr_t model, std::uint32_t uid)
    {
        return model == inventory + GameLayout::Inventory::MenuModel &&
               Read<std::uintptr_t>(inventory) == base + InventoryVtable &&
               Read<std::uint32_t>(model) == uid &&
               (uid & GameLayout::Item::TypeMask) == GameLayout::Item::TypeId;
    }

    std::uintptr_t FindItem(std::uint32_t uid)
    {
        auto pool = base + ItemPoolRva;
        auto index = uid & GameLayout::Item::IndexMask;

        while (index >= GameLayout::Item::EntriesPerPool)
        {
            pool = Read<std::uintptr_t>(pool);

            if (!pool)
                return 0;

            index -= GameLayout::Item::EntriesPerPool;
        }

        const auto item = pool + GameLayout::Item::FirstEntry +
                          static_cast<std::uintptr_t>(index) * GameLayout::Item::EntrySize;

        if (Read<std::uint32_t>(item + GameLayout::Item::Uid) != uid)
            return 0;

        return item;
    }

    bool ReadTransferContext(std::uintptr_t inventory, std::uint32_t uid,
                             QuestStash::TransferContext &context)
    {
        const auto storage = Read<std::uintptr_t>(inventory + GameLayout::Inventory::Storage);
        const auto manager = Read<std::uintptr_t>(base + ManagerRva);

        if (!storage || !manager)
            return false;

        const auto stash = Read<std::uint32_t>(manager + GameLayout::Manager::PersonalStashId);
        const auto open = Read<std::uint32_t>(storage + GameLayout::Storage::ContainerId);
        const auto backpack = Read<std::uint32_t>(inventory + GameLayout::Inventory::BackpackId);

        if (!QuestStash::IsContainer(stash) || open != stash)
            return false;

        const auto item = FindItem(uid);

        if (!item)
            return false;

        const auto owner = Read<std::uintptr_t>(item + GameLayout::Item::Owner);

        if (!owner)
            return false;

        const auto flags = Read<std::uint16_t>(item + GameLayout::Item::Flags);
        context = {
            stash, open, backpack, Read<std::uint32_t>(owner + GameLayout::Owner::ContainerId),
            Read<std::int32_t>(item + GameLayout::Item::Quantity),
            (flags & GameLayout::Item::ProtectedFlag) != 0,
            (flags & GameLayout::Item::EquippedFlag) != 0};
        return true;
    }

    bool EnableTransferRows(std::uintptr_t model, QuestStash::Transfer transfer, std::int32_t quantity)
    {
        const unsigned int action = transfer == QuestStash::Transfer::Deposit
                                        ? GameLayout::Menu::DepositAction
                                        : GameLayout::Menu::RetrieveAction;
        const auto row = model + GameLayout::Menu::FirstRow + action * GameLayout::Menu::RowSize;
        const auto stackRow = row + GameLayout::Menu::RowSize;

        if (Read<std::int32_t>(row + GameLayout::Menu::ActionId) != static_cast<std::int32_t>(action) ||
            Read<std::int32_t>(stackRow + GameLayout::Menu::ActionId) != static_cast<std::int32_t>(action + 1))
        {
            InterlockedExchange(&faulted, 1);
            Log("ERROR: unexpected menu action layout; further overrides disabled.");
            return false;
        }

        // Only menu visibility/enabled bytes change. Native transfer/stack handling,
        // quest flags, item identity, and all other actions are untouched.
        *reinterpret_cast<unsigned char *>(row + GameLayout::Menu::Visible) = 1;
        *reinterpret_cast<unsigned char *>(row + GameLayout::Menu::Enabled) = 1;

        if (quantity > 1)
        {
            *reinterpret_cast<unsigned char *>(stackRow + GameLayout::Menu::Visible) = 1;
            *reinterpret_cast<unsigned char *>(stackRow + GameLayout::Menu::Enabled) = 1;
        }

        return true;
    }

    bool UpdateTransferRows(void *inventory, std::uint32_t uid, void *model)
    {
        const auto inventoryAddress = reinterpret_cast<std::uintptr_t>(inventory);
        const auto modelAddress = reinterpret_cast<std::uintptr_t>(model);

        if (!IsExpectedMenu(inventoryAddress, modelAddress, uid))
            return false;

        QuestStash::TransferContext context{};

        if (!ReadTransferContext(inventoryAddress, uid, context))
            return false;

        const auto transfer = QuestStash::AllowedTransfer(context);

        if (transfer == QuestStash::Transfer::None)
            return false;

        if (!EnableTransferRows(modelAddress, transfer, context.quantity))
            return false;

        if (uid != lastLoggedItem)
        {
            char message[128]{};
            sprintf_s(message, "Allowed quest-item %s menu: item=%08X stash=%08X; quest flags unchanged.",
                      transfer == QuestStash::Transfer::Deposit ? "deposit" : "retrieval", uid, context.personalStash);
            Log(message);
            lastLoggedItem = uid;
        }

        return true;
    }

    void __fastcall OnBuildMenu(void *inventory, std::int32_t grid, std::uint32_t uid, void *model)
    {
        original(inventory, grid, uid, model);

        if (InterlockedCompareExchange(&faulted, 0, 0))
            return;

        __try
        {
            UpdateTransferRows(inventory, uid, model);
        }
        __except (EXCEPTION_EXECUTE_HANDLER)
        {
            InterlockedExchange(&faulted, 1);
            Log("ERROR: native menu inspection failed; further overrides disabled.");
        }
    }

    bool InstallMenuHook()
    {
        base = reinterpret_cast<std::uintptr_t>(GetModuleHandleW(nullptr));
        auto slot = reinterpret_cast<void **>(base + InventoryVtable + BuildMenuSlot);

        if (*slot != reinterpret_cast<void *>(base + BuildMenuRva))
        {
            Log("DISABLED: inventory vtable differs or another mod owns the slot; no hooks installed.");
            return false;
        }

        HMODULE pinned{};

        if (!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_PIN,
                                reinterpret_cast<LPCWSTR>(&OnBuildMenu), &pinned))
        {
            Log("DISABLED: could not retain plugin for the process lifetime.");
            return false;
        }

        original = reinterpret_cast<BuildMenu>(*slot);
        DWORD protection{};

        if (!VirtualProtect(slot, sizeof(void *), PAGE_READWRITE, &protection))
        {
            Log("DISABLED: could not access inventory vtable.");
            return false;
        }

        const auto prior = InterlockedCompareExchangePointer(slot, reinterpret_cast<void *>(&OnBuildMenu),
                                                             reinterpret_cast<void *>(original));
        DWORD ignored{};
        const bool restored = VirtualProtect(slot, sizeof(void *), protection, &ignored) != FALSE;

        if (!restored)
        {
            InterlockedCompareExchangePointer(slot, reinterpret_cast<void *>(original), reinterpret_cast<void *>(&OnBuildMenu));

            if (!VirtualProtect(slot, sizeof(void *), protection, &ignored))
                Log("ERROR: vtable page protection still could not be restored.");

            Log("DISABLED: vtable page protection failed; our hook was rolled back.");
            return false;
        }

        if (prior != reinterpret_cast<void *>(original))
        {
            Log("DISABLED: inventory vtable changed during installation; existing hook preserved.");
            return false;
        }

        return true;
    }

    DWORD WINAPI Start(void *module)
    {
        wchar_t path[MAX_PATH]{};

        if (!GetModuleFileNameW(static_cast<HMODULE>(module), path, MAX_PATH) ||
            wcslen(path) >= MAX_PATH - 1)
            return 1;

        wchar_t *slash = wcsrchr(path, L'\\');

        if (!slash)
            return 1;

        wcscpy_s(slash + 1, MAX_PATH - static_cast<size_t>(slash + 1 - path), L"QuestStash.log");
        logFile = CreateFileW(path, GENERIC_WRITE, FILE_SHARE_READ, nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);

        if (logFile == INVALID_HANDLE_VALUE)
        {
            OutputDebugStringA("QuestStash: cannot open log; plugin disabled.\n");
            return 1;
        }

        Log("Starting restricted personal-stash context-menu prototype.");

        if (!GetModuleFileNameW(nullptr, path, MAX_PATH) || !SupportedImage(path))
        {
            Log("DISABLED: executable unreadable or not the verified Steam 2.1.0 build; no hooks installed.");
            return 1;
        }

        if (!InstallMenuHook())
            return 1;

        Log("ACTIVE: personal-stash quest-item context menus enabled; gameplay verification required.");
        return 0;
    }
}

BOOL WINAPI DllMain(HINSTANCE module, DWORD reason, LPVOID)
{
    if (reason == DLL_PROCESS_ATTACH)
    {
        DisableThreadLibraryCalls(module);
        HANDLE thread = CreateThread(nullptr, 0, Start, module, 0, nullptr);

        if (!thread)
            return FALSE;

        CloseHandle(thread);
    }

    return TRUE;
}
