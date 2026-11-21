#include "QuestStash.cpp"
#include <array>
#include <cassert>
#include <initializer_list>

namespace
{
    // Test fixture for the game-memory layout used by QuestStash.cpp.
    // Keep these test values independent of production's private offsets.
    constexpr std::uintptr_t InventoryModelOffset = 0xB70;
    constexpr std::uintptr_t ManagerStashOffset = 0x80;
    constexpr std::uintptr_t InventoryStorageOffset = 0x6E0;
    constexpr std::uintptr_t InventoryBackpackOffset = 0x6B8;
    constexpr std::uintptr_t StorageOpenContainerOffset = 8;
    constexpr std::uintptr_t ItemOwnerOffset = 0x20;
    constexpr std::uintptr_t ItemFlagsOffset = 0x40;
    constexpr std::uintptr_t ItemQuantityOffset = 0x44;
    constexpr std::uintptr_t ItemUidOffset = 8;
    constexpr std::uintptr_t FirstMenuRowOffset = 0x20;
    constexpr std::uintptr_t MenuRowSize = 0x38;
    constexpr std::uintptr_t MenuActionIdOffset = 0x18;
    constexpr std::uintptr_t MenuRowVisibilityOffset = 0;
    constexpr std::uintptr_t MenuRowEnabledOffset = 1;
    constexpr std::uint32_t BackpackId = 0x38000000;
    constexpr std::uint32_t PersonalStashId = 0x38000001;
    constexpr std::uint32_t ItemUid = 0x30000000;
    constexpr std::uint16_t ProtectedUnequippedItemFlags = 0xD301;
    constexpr int DepositAction = 17;
    constexpr int RetrieveAction = 1;

    template <class T>
    void Write(std::uintptr_t address, T value)
    {
        std::memcpy(reinterpret_cast<void *>(address), &value, sizeof(value));
    }

    void CommitPage(std::uintptr_t address)
    {
        constexpr std::uintptr_t PageSize = 4096;
        const auto page = address & ~(PageSize - 1);
        assert(VirtualAlloc(reinterpret_cast<void *>(page), PageSize, MEM_COMMIT, PAGE_READWRITE));
    }

    class Fixture
    {
    public:
        Fixture()
        {
            allocation = VirtualAlloc(nullptr, 0xB000000, MEM_RESERVE, PAGE_NOACCESS);
            assert(allocation);
            base = reinterpret_cast<std::uintptr_t>(allocation);
            faulted = 0;

            CommitPage(base + ManagerRva);
            CommitPage(base + ItemPoolRva);

            const auto inventoryAddress = Address(inventory);
            const auto managerAddress = Address(manager);
            const auto storageAddress = Address(storage);
            const auto ownerAddress = Address(owner);
            const auto itemAddress = base + ItemPoolRva + 0x10;

            Write(base + ManagerRva, managerAddress);
            Write(inventoryAddress, base + InventoryVtable);
            Write(inventoryAddress + InventoryStorageOffset, storageAddress);
            Write(inventoryAddress + InventoryBackpackOffset, BackpackId);
            Write(managerAddress + ManagerStashOffset, PersonalStashId);
            Write(storageAddress + StorageOpenContainerOffset, PersonalStashId);
            Write(ownerAddress + StorageOpenContainerOffset, BackpackId);
            Write(itemAddress + ItemUidOffset, ItemUid);
            Write(itemAddress + ItemOwnerOffset, ownerAddress);
            Write(itemAddress + ItemFlagsOffset, ProtectedUnequippedItemFlags);
            Write(itemAddress + ItemQuantityOffset, std::int32_t{3});
            Write(ModelAddress(), ItemUid);

            for (int action = 0; action < 27; ++action)
            {
                Write(RowAddress(action) + MenuActionIdOffset, action);
                Write(RowAddress(action) + MenuRowEnabledOffset, std::uint8_t{1});
            }

            std::memcpy(itemBefore.data(), reinterpret_cast<void *>(itemAddress), itemBefore.size());
        }

        ~Fixture()
        {
            if (allocation)
                VirtualFree(allocation, 0, MEM_RELEASE);
        }

        Fixture(const Fixture &) = delete;
        Fixture &operator=(const Fixture &) = delete;

        bool UpdateTransferRows()
        {
            return ::UpdateTransferRows(inventory.data(), ItemUid, reinterpret_cast<void *>(ModelAddress()));
        }

        void SetOwner(std::uint32_t container)
        {
            Write(Address(owner) + StorageOpenContainerOffset, container);
        }

        void SetOpenStorage(std::uint32_t container)
        {
            Write(Address(storage) + StorageOpenContainerOffset, container);
        }

        void SetItemFlags(std::uint16_t flags)
        {
            Write(ItemAddress() + ItemFlagsOffset, flags);
        }

        void SetMenuActionId(int action, int id)
        {
            Write(RowAddress(action) + MenuActionIdOffset, id);
        }

        const std::array<unsigned char, 0x1200> &Inventory() const
        {
            return inventory;
        }

        bool ItemIsUnchanged() const
        {
            return std::memcmp(itemBefore.data(), reinterpret_cast<void *>(ItemAddress()),
                               itemBefore.size()) == 0;
        }

        void ExpectEnabledRows(std::array<unsigned char, 0x1200> &expected,
                               std::initializer_list<int> actions) const
        {
            for (const int action : actions)
            {
                const auto row = InventoryModelOffset + FirstMenuRowOffset + action * MenuRowSize;
                expected[row + MenuRowVisibilityOffset] = 1;
                expected[row + MenuRowEnabledOffset] = 1;
            }
        }

    private:
        template <std::size_t Size>
        static std::uintptr_t Address(const std::array<unsigned char, Size> &bytes)
        {
            return reinterpret_cast<std::uintptr_t>(bytes.data());
        }

        std::uintptr_t ModelAddress() const
        {
            return Address(inventory) + InventoryModelOffset;
        }

        std::uintptr_t RowAddress(int action) const
        {
            return ModelAddress() + FirstMenuRowOffset + action * MenuRowSize;
        }

        std::uintptr_t ItemAddress() const
        {
            return base + ItemPoolRva + 0x10;
        }

        void *allocation{};
        std::array<unsigned char, 0x1200> inventory{};
        std::array<unsigned char, 0x100> manager{};
        std::array<unsigned char, 0x100> storage{};
        std::array<unsigned char, 0x100> owner{};
        std::array<unsigned char, 0x88> itemBefore{};
    };

    void BackpackItemsEnableDepositRows()
    {
        Fixture fixture;
        const auto before = fixture.Inventory();

        assert(fixture.UpdateTransferRows());

        auto expected = before;
        fixture.ExpectEnabledRows(expected, {DepositAction, DepositAction + 1});
        assert(fixture.Inventory() == expected);
        assert(fixture.ItemIsUnchanged());
    }

    void StashedItemsEnableRetrievalRows()
    {
        Fixture fixture;
        fixture.SetOwner(PersonalStashId);
        const auto before = fixture.Inventory();

        assert(fixture.UpdateTransferRows());

        auto expected = before;
        fixture.ExpectEnabledRows(expected, {RetrieveAction, RetrieveAction + 1});
        assert(fixture.Inventory() == expected);
        assert(fixture.ItemIsUnchanged());
    }

    void OtherStorageAndOrdinaryItemsStayUnchanged()
    {
        Fixture fixture;
        const auto before = fixture.Inventory();

        fixture.SetOpenStorage(0x38000002);
        assert(!fixture.UpdateTransferRows());
        assert(fixture.Inventory() == before);

        fixture.SetOpenStorage(PersonalStashId);
        fixture.SetItemFlags(0x9101);
        assert(!fixture.UpdateTransferRows());
        assert(fixture.Inventory() == before);
    }

    void UnknownMenuLayoutDisablesOverrides()
    {
        Fixture fixture;
        fixture.SetOwner(PersonalStashId);
        fixture.SetMenuActionId(RetrieveAction, 99);
        const auto before = fixture.Inventory();

        assert(!fixture.UpdateTransferRows());

        assert(fixture.Inventory() == before);
        assert(faulted);
    }
}

int main()
{
    BackpackItemsEnableDepositRows();
    StashedItemsEnableRetrievalRows();
    OtherStorageAndOrdinaryItemsStayUnchanged();
    UnknownMenuLayoutDisablesOverrides();
    std::puts("PASS: named transfer scenarios preserve item data and reject unknown layouts");
}
