#include "TransferPolicy.h"
#include <cassert>
#include <cstdio>
#include <initializer_list>

namespace
{
    using namespace QuestStash;

    constexpr std::uint32_t BackpackId = 0x38000000;
    constexpr std::uint32_t PersonalStashId = 0x38000001;
    constexpr std::uint32_t OtherContainerId = 0x38000002;
    constexpr std::uint32_t InvalidId = 0xFFFFFFFF;

    TransferContext ProtectedBackpackItem()
    {
        return {
            .personalStash = PersonalStashId,
            .openStorage = PersonalStashId,
            .backpack = BackpackId,
            .owner = BackpackId,
            .quantity = 1,
            .protectedItem = true,
            .equipped = false};
    }

    void TransferDirectionDependsOnOwner()
    {
        auto context = ProtectedBackpackItem();
        assert(AllowedTransfer(context) == Transfer::Deposit);
        context.owner = context.personalStash;
        assert(AllowedTransfer(context) == Transfer::Retrieve);
        context.owner = 0x38000004;
        assert(AllowedTransfer(context) == Transfer::None);
    }

    void OnlyThePersonalStashCanBeOpen()
    {
        auto context = ProtectedBackpackItem();

        for (auto storage : {0u, InvalidId, OtherContainerId, context.backpack})
        {
            context.openStorage = storage;
            assert(AllowedTransfer(context) == Transfer::None);
        }
    }

    void OnlyProtectedUnequippedItemsCanBeTransferred()
    {
        auto context = ProtectedBackpackItem();
        context.protectedItem = false;
        assert(AllowedTransfer(context) == Transfer::None);
        context.protectedItem = true;
        context.equipped = true;
        assert(AllowedTransfer(context) == Transfer::None);
    }

    void QuantityMustBePositive()
    {
        auto context = ProtectedBackpackItem();
        context.quantity = 0;
        assert(AllowedTransfer(context) == Transfer::None);
        context.quantity = -1;
        assert(AllowedTransfer(context) == Transfer::None);
        context.quantity = 100;
        assert(AllowedTransfer(context) == Transfer::Deposit);
    }

    void StashAndBackpackMustBeDistinctValidContainers()
    {
        auto context = ProtectedBackpackItem();
        context.personalStash = context.backpack;
        context.openStorage = context.personalStash;
        assert(AllowedTransfer(context) == Transfer::None);
        context.personalStash = InvalidId;
        context.openStorage = context.personalStash;
        assert(AllowedTransfer(context) == Transfer::None);
    }
}

int main()
{
    TransferDirectionDependsOnOwner();
    OnlyThePersonalStashCanBeOpen();
    OnlyProtectedUnequippedItemsCanBeTransferred();
    QuantityMustBePositive();
    StashAndBackpackMustBeDistinctValidContainers();
    std::puts("PASS: personal-stash-only deposit/retrieval; other containers, equipped items, empty stacks, and ordinary items unchanged");
}
