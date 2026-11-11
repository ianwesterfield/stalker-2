#pragma once
#include <cstdint>

namespace ZoneStash {
struct TransferContext {
    std::uint32_t personalStash;
    std::uint32_t openStorage;
    std::uint32_t backpack;
    std::uint32_t owner;
    std::int32_t quantity;
    bool protectedItem;
    bool equipped;
};

enum class Transfer { None, Deposit, Retrieve };

constexpr bool IsContainer(std::uint32_t id) {
    return (id & 0xF8000000u) == 0x38000000u;
}

constexpr Transfer AllowedTransfer(const TransferContext& context) {
    if (!context.protectedItem || context.equipped || context.quantity <= 0 ||
        !IsContainer(context.personalStash) || !IsContainer(context.backpack) ||
        context.personalStash == context.backpack ||
        context.openStorage != context.personalStash) {
        return Transfer::None;
    }
    if (context.owner == context.backpack) return Transfer::Deposit;
    if (context.owner == context.personalStash) return Transfer::Retrieve;
    return Transfer::None;
}
}
