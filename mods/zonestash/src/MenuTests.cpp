#include "ZoneStash.cpp"
#include <array>
#include <cassert>

namespace {
template<class T> void Put(std::uintptr_t address, T value) {
    std::memcpy(reinterpret_cast<void*>(address), &value, sizeof(value));
}
void CommitPage(std::uintptr_t address) {
    assert(VirtualAlloc(reinterpret_cast<void*>(address & ~std::uintptr_t{4095}),
        4096, MEM_COMMIT, PAGE_READWRITE));
}
}

int main() {
    auto allocation = VirtualAlloc(nullptr, 0xB000000, MEM_RESERVE, PAGE_NOACCESS);
    assert(allocation);
    base = reinterpret_cast<std::uintptr_t>(allocation);
    CommitPage(base + ManagerRva);
    CommitPage(base + ItemPoolRva);
    std::array<unsigned char, 0x1200> inventory{};
    std::array<unsigned char, 0x100> manager{}, storage{}, owner{};
    const auto inv = reinterpret_cast<std::uintptr_t>(inventory.data());
    const auto mgr = reinterpret_cast<std::uintptr_t>(manager.data());
    const auto store = reinterpret_cast<std::uintptr_t>(storage.data());
    const auto own = reinterpret_cast<std::uintptr_t>(owner.data());
    const auto item = base + ItemPoolRva + 0x10;
    const auto model = inv + 0xB70;
    constexpr std::uint32_t uid = 0x30000000;
    Put(base + ManagerRva, mgr);
    Put(inv, base + InventoryVtable);
    Put(inv + 0x6E0, store);
    Put(inv + 0x6B8, std::uint32_t{0x38000000});
    Put(mgr + 0x80, std::uint32_t{0x38000001});
    Put(store + 8, std::uint32_t{0x38000001});
    Put(own + 8, std::uint32_t{0x38000000});
    Put(item + 8, uid);
    Put(item + 0x20, own);
    Put(item + 0x40, std::uint16_t{0xD301});
    Put(item + 0x44, std::int32_t{3});
    Put(model, uid);
    for (int action = 0; action < 27; ++action) {
        Put(model + 0x20 + action * 0x38 + 0x18, action);
        Put(model + 0x20 + action * 0x38 + 1, std::uint8_t{1});
    }
    const auto unchangedInventory = inventory;
    std::array<unsigned char, 0x88> unchangedItem{};
    std::memcpy(unchangedItem.data(), reinterpret_cast<void*>(item), unchangedItem.size());
    assert(UpdateTransferRows(inventory.data(), uid, reinterpret_cast<void*>(model)));
    auto expected = unchangedInventory;
    expected[0xB90 + 17 * 0x38] = 1;
    expected[0xB90 + 18 * 0x38] = 1;
    assert(inventory == expected);
    assert(std::memcmp(unchangedItem.data(), reinterpret_cast<void*>(item), unchangedItem.size()) == 0);

    inventory = unchangedInventory;
    Put(own + 8, std::uint32_t{0x38000001});
    assert(UpdateTransferRows(inventory.data(), uid, reinterpret_cast<void*>(model)));
    expected = unchangedInventory;
    expected[0xB90 + 1 * 0x38] = 1;
    expected[0xB90 + 2 * 0x38] = 1;
    assert(inventory == expected);

    inventory = unchangedInventory;
    Put(store + 8, std::uint32_t{0x38000002});
    assert(!UpdateTransferRows(inventory.data(), uid, reinterpret_cast<void*>(model)));
    assert(inventory == unchangedInventory);
    Put(store + 8, std::uint32_t{0x38000001});
    Put(item + 0x40, std::uint16_t{0x9101});
    assert(!UpdateTransferRows(inventory.data(), uid, reinterpret_cast<void*>(model)));
    assert(inventory == unchangedInventory);
    Put(item + 0x40, std::uint16_t{0xD301});
    Put(model + 0x20 + 1 * 0x38 + 0x18, std::int32_t{99});
    expected = inventory;
    assert(!UpdateTransferRows(inventory.data(), uid, reinterpret_cast<void*>(model)));
    assert(inventory == expected && faulted);
    assert(VirtualFree(allocation, 0, MEM_RELEASE));
    std::puts("PASS: only intended menu bytes changed; quest flags and other actions preserved; unknown layouts rejected");
}
