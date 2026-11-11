#include "TransferPolicy.h"
#include <cassert>
#include <cstdio>
#include <initializer_list>

int main() {
    using namespace ZoneStash;
    TransferContext context{0x38000001, 0x38000001, 0x38000000, 0x38000000, 1, true, false};
    assert(AllowedTransfer(context) == Transfer::Deposit);
    context.owner = context.personalStash;
    assert(AllowedTransfer(context) == Transfer::Retrieve);
    context.owner = 0x38000004;
    assert(AllowedTransfer(context) == Transfer::None);
    context.owner = context.backpack;
    for (auto storage : {0u, 0xFFFFFFFFu, 0x38000002u, context.backpack}) {
        context.openStorage = storage;
        assert(AllowedTransfer(context) == Transfer::None);
    }
    context.openStorage = context.personalStash;
    context.protectedItem = false;
    assert(AllowedTransfer(context) == Transfer::None);
    context.protectedItem = true;
    context.equipped = true;
    assert(AllowedTransfer(context) == Transfer::None);
    context.equipped = false;
    context.quantity = 0;
    assert(AllowedTransfer(context) == Transfer::None);
    context.quantity = -1;
    assert(AllowedTransfer(context) == Transfer::None);
    context.quantity = 100;
    assert(AllowedTransfer(context) == Transfer::Deposit);
    context.personalStash = context.backpack;
    context.openStorage = context.personalStash;
    assert(AllowedTransfer(context) == Transfer::None);
    context.personalStash = 0xFFFFFFFF;
    context.openStorage = context.personalStash;
    assert(AllowedTransfer(context) == Transfer::None);
    std::puts("PASS: personal-stash-only deposit/retrieval; other containers, equipped items, empty stacks, and ordinary items unchanged");
}
