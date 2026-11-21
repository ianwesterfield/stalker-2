-- Pin-pull splice: the throw runs RGD5 montages whose first section is literally
-- named "TearOff" — the pin yank, on a bottle that has no pin. GSC authored it as
-- its own section on both the weapon and the body montage, so the cut point is read
-- from the asset rather than guessed (0.500s two-handed, 0.833s with the detector
-- up). Each new montage starts at the section boundary; the montage blend-in covers
-- the pose change.
local Hands = require("hands")
local Unreal = require("unreal")

local PinPull = {}
local fp = Hands.fp

local TEAR_SECTION = "tearoff"

local function readNumber(struct, property)
    local value
    local isRead = pcall(function()
        value = struct[property]
    end)

    if not isRead then
        return -1
    end

    return type(value) == "number" and value or -1
end

local function readName(struct, property)
    local value = "?"

    pcall(function()
        value = struct[property]:ToString()
    end)

    return value
end

local function shortName(object)
    local name = "?"

    pcall(function()
        local fullName = object:GetFullName()
        name = fullName:match("([^%.]+)$") or fullName
    end)

    return name
end

-- End of the pin-pull section; nil for montages that have none (equip, detector).
local function tearOffEnd(montage)
    local endTime

    pcall(function()
        montage.CompositeSections:ForEach(function(_, element)
            local section = element:get()

            if readName(section, "SectionName"):lower() == TEAR_SECTION then
                local beginTime = readNumber(section, "SegmentBeginTime")
                local length = readNumber(section, "SegmentLength")

                if beginTime >= 0 and length > 0 then
                    endTime = beginTime + length
                end
            end
        end)
    end)

    return endTime
end

-- Latches per rig on the montage name, so re-driving the same montage is a no-op.
local function watchMontage(rig, instance)
    local montage

    pcall(function()
        montage = instance:GetCurrentActiveMontage()
    end)

    if not (montage and montage:IsValid()) then
        Hands.mp.cur[rig] = nil
        return
    end

    local name = shortName(montage)
    local latch = Hands.mp.cur[rig]

    if latch and latch.name == name then
        return
    end

    latch = {
        name = name,
        tear = tearOffEnd(montage),
    }
    Hands.mp.cur[rig] = latch

    if latch.tear then
        -- land just inside TearOff: letting the engine leave the section keeps
        -- whatever next-section branch the throw input already queued
        pcall(function()
            instance:Montage_SetPosition(montage, latch.tear - 0.002)
        end)
    end
end

local function tick()
    -- our molotov is the only thing worth splicing
    if not Unreal.isAlive(fp.rag) then
        return
    end

    local weaponMesh = Unreal.isAlive(fp.mesh) and fp.mesh or nil

    if not (weaponMesh and weaponMesh:IsValid()) then
        return
    end

    local weaponInstance, body

    pcall(function()
        weaponInstance = weaponMesh.AnimScriptInstance
    end)

    if weaponInstance and weaponInstance:IsValid() then
        pcall(watchMontage, "wpn", weaponInstance)
    end

    pcall(function()
        body = weaponMesh:GetAttachParent()
    end)

    if body and body:IsValid() then
        local bodyInstance

        pcall(function()
            bodyInstance = body.AnimScriptInstance
        end)

        if bodyInstance and bodyInstance:IsValid() then
            pcall(watchMontage, "body", bodyInstance)
        end
    end
end

-- Polled while the bottle is lit; the montage-name latch makes each splice fire once.
function PinPull.start()
    LoopInGameThreadWithDelay(60, function()
        if fp.rag then
            ExecuteInGameThread(function()
                pcall(tick)
            end)
        end

        return false
    end)
end

return PinPull
