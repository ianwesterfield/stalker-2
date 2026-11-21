-- Thrown grenades: spawn watcher, flight-look tuning, impact/fuse detonation.
local GroundFire = require("ground_fire")
local RagFire = require("rag_fire")
local UEHelpers = require("UEHelpers")
local Unreal = require("unreal")

local GrenadeTracker = {}

-- Flight look: in flight the rag cloth droops along a fixed trail on THIS grenade's
-- MIDs only. The actor is constructed AT the throw and short lobs land in ~300ms,
-- so apply on a fast retry ladder from frame 1 rather than after the 300ms SID
-- check; the MolotovRag name gate holds off until the cfg materials are actually in.
local FLIGHT_DROOP = 6.0 -- pin offset = (dir - tangent) * vcR * this; 1.0 is ~2cm (sub-visible)

-- static twin has no bones: pin the rag's droop direction instead — Skif's toss
-- is consistent, so a fixed up+slightly-right-of-throw trail reads as drag
local FLIGHT_PIN_BACK = 0.25
local FLIGHT_PIN_RIGHT = 0.35
local FLIGHT_PIN_UP = 0.75

-- Live grenades for this mod instance; a vanished actor's last position = detonation
-- site. Entries stay in the list once dead (alive=false); seenGrenades never shrinks.
local seenGrenades = {}
local tracked = {}
local trackedCount = 0

local function readSID(object)
    local value = object.SID
    return tostring(value and value.ToString and value:ToString() or value)
end

local function flightPinDir()
    local yaw = 0

    pcall(function()
        yaw = UEHelpers.GetPlayerController():GetControlRotation().Yaw
    end)

    local yawRadians = math.rad(yaw)
    local forwardX, forwardY = math.cos(yawRadians), math.sin(yawRadians)
    local dx = -forwardY * FLIGHT_PIN_RIGHT - forwardX * FLIGHT_PIN_BACK
    local dy = forwardX * FLIGHT_PIN_RIGHT - forwardY * FLIGHT_PIN_BACK
    local dz = FLIGHT_PIN_UP
    local length = math.sqrt(dx * dx + dy * dy + dz * dz)

    return { R = dx / length, G = dy / length, B = dz / length, A = 0.0 }
end

local function tuneFlightLook(grenade, attempt)
    ExecuteInGameThread(function()
        local isDone = false

        pcall(function()
            if not Unreal.isAlive(grenade) then
                isDone = true
                return
            end

            local sid

            pcall(function()
                local text = readSID(grenade)

                if text ~= "" and text ~= "nil" then
                    sid = text
                end
            end)

            if sid and not sid:find("Molotov") then
                isDone = true
                return -- RGD5/F1
            end

            local smcClass = StaticFindObject("/Script/Engine.StaticMeshComponent")
            local component = smcClass and smcClass:IsValid() and grenade:GetComponentByClass(smcClass) or nil

            if not (component and component:IsValid()) then
                return -- comp not built yet, retry
            end

            local pin = flightPinDir()
            local tuned = 0

            for slotIndex = 0, component:GetNumMaterials() - 1 do
                local material = component:GetMaterial(slotIndex)
                local fullName = (material and material:IsValid()) and material:GetFullName() or ""

                if fullName:find("MolotovRag", 1, true) then
                    local mid = component:CreateDynamicMaterialInstance(slotIndex, material, FName("None"))

                    if mid and mid:IsValid() then
                        mid:SetScalarParameterValue(FName("DroopStrength"), FLIGHT_DROOP)

                        pcall(function()
                            mid:SetVectorParameterValue(FName("DroopDir"), pin)
                        end)

                        tuned = tuned + 1
                    end
                end
            end

            if tuned > 0 then
                isDone = true
                Unreal.log(string.format("flightlook: %d slot(s) tuned (attempt %d)", tuned, attempt))
            end

            -- rag materials not on the comp yet (cfg mesh still initializing) -> retry
        end)

        if not isDone and attempt < 12 then
            ExecuteInGameThreadWithDelay(50, function()
                tuneFlightLook(grenade, attempt + 1)
            end)
        end
    end)
end

local function untrack(entry)
    entry.alive = false
    trackedCount = trackedCount - 1
end

local function detonate(entry, x, y, z, how)
    if entry.detonated then
        return
    end

    entry.detonated = true

    if entry.alive then
        untrack(entry)
    end

    local grenade = Unreal.isAlive(entry.actor) and entry.actor or nil

    pcall(function()
        if grenade and grenade:IsValid() then
            grenade:Explode()
        end
    end)

    Unreal.log(string.format("BOOM (%s) at %.0f %.0f %.0f", how, x, y, z))

    local okFire, fireError = pcall(GroundFire.spawn, x, y, z, entry.hx, entry.hy)

    if not okFire then
        Unreal.log("FIRE handler error: " .. tostring(fireError))
    end

    local okIgnite, igniteError = pcall(GroundFire.igniteNearby, x, y, z)

    if not okIgnite then
        Unreal.log("ignite error: " .. tostring(igniteError))
    end
end

-- Impact detonation: glass breaks on contact. Native Grenade:OnHit (dump-verified
-- UFunction, classic hit signature) fires on any blocking contact; Explode() is the
-- on-demand boom. The cfg TimeToExplode (6s) is an engine-side failsafe only.
local function hookImpacts()
    local ok, errorMessage = pcall(function()
        -- hook body = pointer match + flag ONLY: unwrapping the FHitResult param /
        -- calling Explode() inside the physics hit dispatch AV'd in UE4SS (0x38);
        -- the 100ms tracker loop detonates from its proven-safe context instead
        RegisterHook("/Script/Stalker2.Grenade:OnHit", function(selfParam)
            pcall(function()
                if trackedCount == 0 then
                    return
                end

                local grenadeAddress = Unreal.address(selfParam:get())

                if not grenadeAddress then
                    return
                end

                for _, entry in ipairs(tracked) do
                    if
                        entry.alive
                        and entry.armed
                        and not entry.detonated
                        and not entry.hitPending
                        and entry.addr == grenadeAddress
                    then
                        entry.hitPending = true
                        return
                    end
                end
            end)
        end)
    end)

    Unreal.log(
        ok and "impact hook armed on Grenade:OnHit"
            or ("impact hook FAILED (fuse fallback only): " .. tostring(errorMessage))
    )
end

local function untrackIfNotMolotov(grenade, grenadeAddress)
    ExecuteInGameThread(function()
        local ok, errorMessage = pcall(function()
            if not Unreal.isAlive(grenade) then
                Unreal.log("bottleize: actor gone")
                return
            end

            local sid = "unreadable"

            pcall(function()
                local text = readSID(grenade)

                if text ~= "" and text ~= "nil" then
                    sid = text
                end
            end)

            Unreal.log("bottleize: SID = " .. sid)

            if not (sid:find("Molotov") or sid == "unreadable") then
                Unreal.log("bottleize: not a molotov, skipping")

                for _, entry in ipairs(tracked) do
                    if entry.alive and entry.addr == grenadeAddress then
                        untrack(entry)
                        Unreal.log("untracked non-molotov (no fire for RGD5/F1)")
                    end
                end

                return
            end

            Unreal.log("bottleize: cfg mesh in use")
        end)

        if not ok then
            Unreal.log("bottleize ERR: " .. tostring(errorMessage))
        end
    end)
end

local function watchSpawns()
    ExecuteInGameThread(function()
        pcall(function()
            for _, grenade in ipairs(FindAllOf("BP_Grenade_C") or {}) do
                if grenade:IsValid() and not grenade:GetFullName():find("Default__") then
                    local grenadeAddress = Unreal.address(grenade)

                    if grenadeAddress and not seenGrenades[grenadeAddress] then
                        seenGrenades[grenadeAddress] = true
                        tracked[#tracked + 1] = {
                            addr = grenadeAddress,
                            actor = grenade,
                            x = 0,
                            y = 0,
                            z = 0,
                            alive = true,
                            seen = 0,
                        }
                        trackedCount = trackedCount + 1
                        Unreal.log("grenade spawned (equipped)")
                        RagFire.douse("thrown")

                        ExecuteInGameThreadWithDelay(16, function()
                            tuneFlightLook(grenade, 1)
                        end)

                        ExecuteInGameThreadWithDelay(300, function()
                            untrackIfNotMolotov(grenade, grenadeAddress)
                        end)
                    end
                end
            end
        end)
    end)
end

local function isOrigin(location)
    return location.X == 0 and location.Y == 0 and location.Z == 0
end

local function updateFlight(entry, grenade)
    local location = grenade:K2_GetActorLocation()

    if isOrigin(location) then
        local root = grenade.RootComponent

        if root and root:IsValid() then
            location = root:K2_GetComponentLocation()
        end
    end

    if isOrigin(location) then
        return
    end

    if entry.seen > 0 then
        local dx, dy, dz = location.X - entry.x, location.Y - entry.y, location.Z - entry.z
        local horizontalSquared = dx * dx + dy * dy

        if horizontalSquared > 60 * 60 then
            local horizontal = math.sqrt(horizontalSquared)
            entry.hx, entry.hy = dx / horizontal, dy / horizontal -- latest flight heading
        end

        -- >120cm between 100ms reads = 12 m/s: throws hit ~15-25, sprint ~7
        if not entry.armed and horizontalSquared + dz * dz > 120 * 120 then
            entry.armed = true
            -- fallback only; a 45-deg lob at 20 m/s flies ~3s
            entry.boomAt = os.clock() + 3.5
            Unreal.log("thrown - impact watch armed")
        end
    end

    entry.x, entry.y, entry.z = location.X, location.Y, location.Z
    entry.seen = (entry.seen or 0) + 1

    if entry.seen % 10 == 1 then
        Unreal.log(string.format("tracking %.0f %.0f %.0f", entry.x, entry.y, entry.z))
    end
end

local function handleVanished(entry)
    untrack(entry)

    if entry.armed and not entry.detonated then
        -- died mid-fuse = engine detonated it; last position is ground zero
        entry.detonated = true
        Unreal.log(string.format("BOOM (actor died) at %.0f %.0f %.0f", entry.x, entry.y, entry.z))

        local okFire, fireError = pcall(GroundFire.spawn, entry.x, entry.y, entry.z, entry.hx, entry.hy)

        if not okFire then
            Unreal.log("FIRE handler error: " .. tostring(fireError))
        end
    else
        Unreal.log(string.format("grenade despawned unarmed (reads=%d)", entry.seen or 0))
    end
end

local function trackEntry(entry)
    local grenade = Unreal.isAlive(entry.actor) and entry.actor or nil

    -- deferred impact: flagged by the OnHit hook, executed here
    if entry.hitPending and not entry.detonated then
        entry.hitPending = nil

        local sid, impactX, impactY, impactZ = "", entry.x, entry.y, entry.z

        if grenade then
            pcall(function()
                sid = readSID(grenade)
            end)

            pcall(function() -- resting spot = true ground zero
                local location = grenade:K2_GetActorLocation()

                if not isOrigin(location) then
                    impactX, impactY, impactZ = location.X, location.Y, location.Z
                end
            end)
        end

        if sid:find("Molotov") then
            detonate(entry, impactX, impactY, impactZ, "impact")
            return
        end

        -- non-molotov not yet untracked by the SID check: engine timer keeps it
    end

    -- fallback fuse: soft landings (water/bushes) may never fire OnHit
    if entry.armed and os.clock() >= entry.boomAt then
        detonate(entry, entry.x, entry.y, entry.z, "fuse fallback")
        return
    end

    if grenade then
        updateFlight(entry, grenade)
    else
        handleVanished(entry)
    end
end

function GrenadeTracker.start()
    hookImpacts()

    LoopInGameThreadWithDelay(60, function()
        watchSpawns()
        return false
    end)

    LoopInGameThreadWithDelay(100, function()
        if trackedCount == 0 then
            return false
        end

        ExecuteInGameThread(function()
            for _, entry in ipairs(tracked) do
                if entry.alive then
                    local ok = pcall(trackEntry, entry)

                    if not ok and entry.alive then
                        untrack(entry)
                        Unreal.log("tracker error; entry dropped")
                    end
                end
            end
        end)

        return false
    end)
end

return GrenadeTracker
