-- Holding the lit bottle singes: slow HP drain while the rag fire burns in hand.
-- Gate = fp.rag (the Niagara fire is literally lit; douse paths clear it on throw
-- and holster). The floor keeps carelessness painful but never lethal.
--
-- Silent by construction. Every *damage* route has feedback welded on engine-side:
-- Burn brings the fire roar + red screen edges, Strike brings Skif's pain grunt on
-- every tick. Obj:ForceSetHP writes HP straight in, skipping the damage pipeline
-- entirely, so nothing reacts to it. ObjGetHP reads float but ForceSetHP takes
-- int32 — fractional ticks bank in `debt` and land as whole points.
local Hands = require("hands")
local UEHelpers = require("UEHelpers")
local Unreal = require("unreal")

local HoldBurn = {}
local fp = Hands.fp

-- Cleared at runtime if the engine rejects ForceSetHP; the timer then cancels itself.
HoldBurn.isEnabled = true

local HP_PER_TICK = 0.5
local TICK_PERIOD_MS = 1500 -- ~0.33 HP/s
local HP_FLOOR = 8.0 -- stop singeing below this HP

local progress = {
    ticks = 0,
    isProbed = false,
    debt = 0,
}

local function singe()
    if not Unreal.isAlive(fp.rag) then
        return
    end

    local mediator = StaticFindObject(Unreal.CPP_MEDIATOR_PATH)
    local pawn

    pcall(function()
        pawn = UEHelpers.GetPlayerController().Pawn
    end)

    -- every exit here is silent, so say which piece is missing
    if not progress.isProbed then
        progress.isProbed = true
        Unreal.log(
            string.format("hold-burn: probe cm=%s pawn=%s", tostring(mediator ~= nil), tostring(pawn ~= nil))
        )
    end

    if not (mediator and mediator:IsValid() and pawn and pawn:IsValid()) then
        return
    end

    local hp = mediator:ObjGetHP(pawn)

    if type(hp) ~= "number" or hp <= HP_FLOOR then
        return
    end

    progress.debt = progress.debt + HP_PER_TICK
    local whole = math.floor(progress.debt)

    if whole < 1 then
        return
    end

    progress.debt = progress.debt - whole
    local target = math.max(math.floor(HP_FLOOR), math.floor(hp) - whole)

    local isWritten = pcall(function()
        pawn:ForceSetHP(target)
    end)

    if not isWritten then
        HoldBurn.isEnabled = false
        Unreal.log("hold-burn: ForceSetHP rejected - singe disabled")
        return
    end

    progress.ticks = progress.ticks + 1

    if progress.ticks == 1 or progress.ticks % 10 == 0 then
        Unreal.log(string.format("hold-burn: tick %d  hp %.1f -> %d", progress.ticks, hp, target))
    end
end

function HoldBurn.start()
    local timer

    timer = LoopInGameThreadWithDelay(TICK_PERIOD_MS, function()
        if not HoldBurn.isEnabled then
            CancelDelayedAction(timer)
            return
        end

        if not fp.rag then
            progress.ticks, progress.isProbed, progress.debt = 0, false, 0
            return false
        end

        ExecuteInGameThread(function()
            pcall(singe)
        end)

        return false
    end)
end

return HoldBurn
