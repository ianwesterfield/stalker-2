-- The molotov craft: fires the vodka+bandage quest chain, logs the inventory counts
-- around it, and repaints the open backpack while the chain lands.
local UEHelpers = require("UEHelpers")
local Unreal = require("unreal")

local Crafting = {}

local function playerPawn()
    local pawn

    pcall(function()
        pawn = UEHelpers.GetPlayerController().Pawn
    end)

    return pawn
end

-- The backpack never repaints when items change underneath it, so a craft looks
-- like it did nothing until you close the screen. Nudge the live widget instead.
-- SortInventory would also rebuild but reorders the player's pack, so it is out.
-- Only ever called from the craft path, where the player is demonstrably standing
-- in an open inventory: bursting this during a firefight (bandaging moves items in
-- and out) pokes a torn-down widget and crashes. pcall cannot catch that AV, so
-- the guard has to be "is it actually on screen", not a try/catch.
-- Only UpdateInputDependent: OnVisibilityChangedEvent is an engine-fed handler.
local function nudgeInventoryUI()
    local inventory

    pcall(function()
        inventory = Unreal.liveInstance("InventoryNew")
    end)

    if not (inventory and inventory:IsValid()) then
        return
    end

    local isVisible = false

    pcall(function()
        isVisible = inventory:IsVisible()
    end)

    if not isVisible then
        return
    end

    pcall(function()
        inventory:UpdateInputDependent()
    end)
end

-- The quest chain lands one node at a time, so repaint across the whole window.
local function nudgeBurst(count, interval)
    for index = 0, count - 1 do
        ExecuteInGameThreadWithDelay(index * interval, function()
            ExecuteInGameThread(function()
                pcall(nudgeInventoryUI)
            end)
        end)
    end
end

local function ingredientCounts(mediator, pawn)
    return mediator:GetItemsCountInInventory(pawn, "Vodka"),
        mediator:GetItemsCountInInventory(pawn, "Bandage"),
        mediator:GetItemsCountInInventory(pawn, "GrenadeMolotov")
end

local function reportOutcome(tag, moloBefore, done)
    -- re-resolve: the pawn wrapper from 900ms ago may be dead
    local mediator = StaticFindObject(Unreal.CPP_MEDIATOR_PATH)
    local pawn = playerPawn()

    if not (mediator and mediator:IsValid() and pawn and pawn:IsValid()) then
        Unreal.log("craft: follow-up lost cm/pawn")

        if done then
            done()
        end

        return
    end

    local vodka, bandage, molotov = ingredientCounts(mediator, pawn)
    Unreal.log(
        string.format(
            "craft[%s]: after  vodka=%s bandage=%s molotov=%s",
            tag,
            tostring(vodka),
            tostring(bandage),
            tostring(molotov)
        )
    )

    if type(molotov) == "number" and type(moloBefore) == "number" and molotov > moloBefore then
        Unreal.log("craft: SUCCESS - rag-wrapped a bottle")
    else
        Unreal.log("craft: no molotov granted")
    end

    pcall(nudgeInventoryUI)

    if done then
        done()
    end
end

-- Logs all three counts so a partial run (vodka taken but no molotov) is
-- distinguishable from the quest gate refusing outright. `done` always runs once.
function Crafting.craft(tag, sid, done)
    ExecuteInGameThread(function()
        local ok, errorMessage = pcall(function()
            local mediator = StaticFindObject(Unreal.CPP_MEDIATOR_PATH)
            local consoleManager = Unreal.liveInstance("CustomConsoleManagerAA")
            local pawn = playerPawn()

            if not (consoleManager and mediator and mediator:IsValid() and pawn and pawn:IsValid()) then
                Unreal.log("craft: missing aa/cm/pawn")

                if done then
                    done()
                end

                return
            end

            local vodka, bandage, molotov = ingredientCounts(mediator, pawn)
            Unreal.log(
                string.format(
                    "craft[%s]: before vodka=%s bandage=%s molotov=%s",
                    tag,
                    tostring(vodka),
                    tostring(bandage),
                    tostring(molotov)
                )
            )

            local okCall, callError = pcall(function()
                consoleManager:XStartQuestNodeBySID(sid)
            end)

            if not okCall then
                Unreal.log("craft: call ERR " .. tostring(callError))
            end

            nudgeBurst(12, 250)

            ExecuteInGameThreadWithDelay(900, function()
                ExecuteInGameThread(function()
                    reportOutcome(tag, molotov, done)
                end)
            end)
        end)

        if not ok then
            Unreal.log("craft ERR: " .. tostring(errorMessage))

            if done then
                done()
            end
        end
    end)
end

-- Vodka and bandage counts, or nil when the player can't be read.
function Crafting.playerCounts()
    local mediator = StaticFindObject(Unreal.CPP_MEDIATOR_PATH)
    local pawn = playerPawn()

    if not (mediator and mediator:IsValid() and pawn and pawn:IsValid()) then
        return nil
    end

    local vodka = mediator:GetItemsCountInInventory(pawn, "Vodka")
    local bandage = mediator:GetItemsCountInInventory(pawn, "Bandage")

    if type(vodka) ~= "number" or type(bandage) ~= "number" then
        return nil
    end

    return vodka, bandage
end

return Crafting
