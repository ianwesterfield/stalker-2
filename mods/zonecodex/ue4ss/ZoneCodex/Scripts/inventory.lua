-- Carried quantities from the active save. Game thread only.
-- GetItemsCountInInventory reports what the player carries right now, not stash contents
-- or lifetime discoveries, so the UI labels it "carried now".
local Unreal = require("unreal")

local Inventory = {}

---@param tab ZoneCodexTab
---@return ZoneCodexCounts|nil counts
---@return string|nil errorMessage
function Inventory.read(tab)
    local mediator = StaticFindObject(Unreal.CPP_MEDIATOR)

    if not Unreal.isValid(mediator) then
        return nil, "CppMediator unavailable"
    end

    local pawn = Unreal.playerPawn()

    if not pawn then
        return nil, "no player pawn (main menu or loading?)"
    end

    local counts = {}

    for _, entry in ipairs(tab.entries) do
        local total = 0

        for _, sid in ipairs(entry.sids) do
            local quantity = mediator:GetItemsCountInInventory(pawn, sid)

            if type(quantity) ~= "number" or quantity < 0 then
                return nil, string.format("unexpected count for %s: %s", sid, tostring(quantity))
            end

            total = total + math.floor(quantity)
        end

        counts[entry.id] = total
    end

    return counts
end

return Inventory
