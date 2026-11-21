-- MolotovFire: wires the molotov's runtime features together. Load order matters:
-- the harness and the game both see the timers in exactly this registration order.
local CraftMenu = require("craft_menu")
local GrenadeTracker = require("grenade_tracker")
local GroundFire = require("ground_fire")
local Hands = require("hands")
local HoldBurn = require("hold_burn")
local PinPull = require("pin_pull")
local RagFire = require("rag_fire")
local Unreal = require("unreal")

Unreal.log("loaded")

assert(
    type(LoopInGameThreadWithDelay) == "function"
        and type(ExecuteInGameThreadWithDelay) == "function"
        and type(CancelDelayedAction) == "function",
    "MolotovFire requires UE4SS game-thread timer APIs"
)

local seenAnimInstances = {}

-- Each new molotov hands AnimBP instance is a fresh equip: kick the rag physics
-- and light the rag.
local function watchEquips()
    for _, anim in ipairs(FindAllOf("AnimBP_Rgd5_fp_C") or {}) do
        if anim:IsValid() and not anim:GetFullName():find("Default__") then
            local animAddress = Unreal.address(anim)

            if animAddress and not seenAnimInstances[animAddress] and Hands.currentRagMesh(anim) then
                seenAnimInstances[animAddress] = true
                Hands.equipGeneration = Hands.equipGeneration + 1
                RagFire.kickPhysics(anim, 1)
                RagFire.light(anim, 1)
            end
        end
    end
end

-- Restore the hands when their anim changes (lowered / thrown / weapon switched).
local function checkHandsChanged()
    local fp = Hands.fp
    local keep = false

    pcall(function()
        if Unreal.isAlive(fp.mesh) and Unreal.isAlive(fp.rag) then
            local current = fp.mesh.AnimScriptInstance
            keep = current and current:IsValid() and current:GetFullName() == fp.animName
        end
    end)

    if fp.rag and not keep then
        Unreal.log("FP: hands changed - bottle away")
        Hands.restore()
    end
end

GroundFire.start()
GrenadeTracker.start()
PinPull.start()

LoopInGameThreadWithDelay(120, function()
    ExecuteInGameThread(function()
        pcall(watchEquips)
    end)

    return false
end)

LoopInGameThreadWithDelay(500, function()
    if not Hands.fp.rag then
        return false
    end

    ExecuteInGameThread(checkHandsChanged)
    return false
end)

HoldBurn.start()
CraftMenu.start()
