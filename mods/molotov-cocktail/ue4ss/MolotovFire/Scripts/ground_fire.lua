-- Ground fire: the burning pool left by a detonation, and the NPC burns it causes.
local UEHelpers = require("UEHelpers")
local Unreal = require("unreal")

local GroundFire = {}

-- Ambient bonfire BP (env set-dressing): self-contained VFX+light, no anomaly-spawner
-- context needed. ClassicFireAnomaly null-derefs when raw-spawned.
local FIRE_CLASS_PATH = "/Game/_Stalker_2/VFX/Environment/BonFire/Blueprint/BP_BonFire.BP_BonFire_C"

-- Real petrol-bomb pool: intense ~25s, rim dies first, heart gone by ~45s.
-- { count, min/max distance (cm), min/max lifetime (s), visual scale }
local RINGS = {
    { count = 1, distMin = 0, distMax = 0, lifeMin = 40, lifeMax = 45, scale = 1.4 }, -- heart of the fire
    { count = 4, distMin = 35, distMax = 65, lifeMin = 32, lifeMax = 40, scale = 1.2 }, -- body
    { count = 5, distMin = 70, distMax = 110, lifeMin = 24, lifeMax = 32, scale = 1.0 }, -- ragged edge
}

local BURN_RADIUS = 650 -- matches ExplosionMolotov ConcussionRadius
local POOL_BURN_RADIUS = 210 -- standing in a patch's flames (visuals run 1.0-1.4x bonfire)
local Z_NUDGE = -30 -- BonFire flames emit from log-pile top; sink actor to grass level

-- Live patches ({ actor, addr, dieAt }) for this mod instance; the expiry loop
-- removes them once their lifetime ends or their actor dies.
local fires = {}
local poolLogAt = 0

local function groundZ(world, x, y, zHint)
    local systemLibrary = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")

    if not (systemLibrary and systemLibrary:IsValid()) then
        return zHint
    end

    local hit = {}

    local ok, hitSomething = pcall(function()
        -- trace Visibility channel: +150 clears tall grass, -1500 reaches downslope
        return systemLibrary:LineTraceSingle(
            world,
            { X = x, Y = y, Z = zHint + 150 },
            { X = x, Y = y, Z = zHint - 1500 },
            0,
            false,
            {},
            0,
            hit,
            true,
            { R = 0, G = 0, B = 0, A = 1 },
            { R = 0, G = 0, B = 0, A = 1 },
            0.0
        )
    end)

    if ok and hitSomething then
        local impactPoint = hit.ImpactPoint or hit.Location

        local okZ, impactZ = pcall(function()
            return impactPoint.Z
        end)

        if okZ and type(impactZ) == "number" then
            return impactZ
        end
    end

    return zHint
end

function GroundFire.spawn(x, y, z, headingX, headingY)
    -- splash axis = throw heading (random when unknown); pool stretches 1.5x along, 0.8x across
    if not (headingX and headingY) or (headingX == 0 and headingY == 0) then
        local angle = math.random() * 2 * math.pi
        headingX, headingY = math.cos(angle), math.sin(angle)
    end

    local fireClass = StaticFindObject(FIRE_CLASS_PATH)

    if not (fireClass and fireClass:IsValid()) then
        fireClass = LoadAsset(FIRE_CLASS_PATH)
    end

    if not (fireClass and fireClass:IsValid()) then
        Unreal.log("FIRE: class failed to load")
        return
    end

    local gameplayStatics = StaticFindObject("/Script/Engine.Default__GameplayStatics")
    local world = UEHelpers.GetWorld()

    if not (gameplayStatics and gameplayStatics:IsValid() and world and world:IsValid()) then
        Unreal.log("FIRE: no GameplayStatics/world")
        return
    end

    -- no extra flash here: the engine explosion (pak ExplosionPrototype) already
    -- provides the fireball+whoosh; a second NS_Barrel_Explo reads as a double boom
    local spawned = 0

    for _, ring in ipairs(RINGS) do
        for patchIndex = 1, ring.count do
            -- even spacing + jitter reads organic instead of clock-face
            local patchAngle = (patchIndex / ring.count) * 2 * math.pi + (math.random() - 0.5)
            local distance = ring.distMin + math.random() * (ring.distMax - ring.distMin)
            local lifetime = ring.lifeMin + math.random() * (ring.lifeMax - ring.lifeMin)
            -- decompose offset into along/across the splash axis, then stretch
            local along = math.cos(patchAngle) * distance * 1.5 + 30 -- +30: splash carries past impact
            local across = math.sin(patchAngle) * distance * 0.8
            local patchX = x + headingX * along - headingY * across
            local patchY = y + headingY * along + headingX * across
            local patchZ = groundZ(world, patchX, patchY, z) + Z_NUDGE
            local transform = {
                Rotation = { X = 0, Y = 0, Z = 0, W = 1 },
                Translation = { X = patchX, Y = patchY, Z = patchZ },
                Scale3D = { X = ring.scale, Y = ring.scale, Z = ring.scale },
            }

            local ok, errorMessage = pcall(function()
                -- UE 5.5: both spawn calls take ESpawnActorScaleMethod (1 = MultiplyWithRoot)
                local actor =
                    gameplayStatics:BeginDeferredActorSpawnFromClass(world, fireClass, transform, 1, nil, 1)

                if actor and actor:IsValid() then
                    gameplayStatics:FinishSpawningActor(actor, transform, 1)

                    -- keep flames/light/sound/BurnTriggerCollider; ditch the log-pile mesh
                    pcall(function()
                        local logPile = actor.SM_vil_fire_death_01

                        if logPile and logPile:IsValid() then
                            logPile:SetHiddenInGame(true, false)
                            logPile:SetCollisionEnabled(0)
                        end
                    end)

                    fires[#fires + 1] = {
                        actor = actor,
                        addr = Unreal.address(actor),
                        dieAt = os.clock() + lifetime,
                    }
                    spawned = spawned + 1
                end
            end)

            if not ok then
                Unreal.log("FIRE spawn error: " .. tostring(errorMessage))
            end
        end
    end

    Unreal.log(string.format("FIRE: %d patches burning at %.0f %.0f %.0f", spawned, x, y, z))
end

-- Engine's TIMED detonation applies cfg ConcussionEffects; manual Explode() bypasses
-- that wrapper (NPCs flinched but never ignited) — so burn them via the cheat shard.
-- Shared by the splash and the pool refresh: apply MolotovBurning to every NPC within
-- radius of ANY point in `points` ({ {x,y,z,r}, ... }). tag=nil silences the report.
local function burnNPCsNear(points, tag)
    local consoleManager = Unreal.liveInstance("CustomConsoleManagerRK")
    local mediator = StaticFindObject(Unreal.CPP_MEDIATOR_PATH)

    if not (consoleManager and mediator and mediator:IsValid()) then
        if tag then
            Unreal.log(tag .. ": no RK shard/CppMediator")
        end

        return
    end

    local pawn

    pcall(function()
        local playerController = UEHelpers.GetPlayerController()

        if playerController and playerController:IsValid() then
            pawn = playerController.Pawn
        end
    end)

    local applied = 0

    for _, npc in ipairs(FindAllOf("Obj") or {}) do -- Obj = native character base (ZoneLink-proven)
        pcall(function()
            if not npc:IsValid() or npc:GetFullName():find("Default__") then
                return
            end

            if pawn and pawn:IsValid() and npc:GetAddress() == pawn:GetAddress() then
                return
            end

            local location = npc:K2_GetActorLocation()
            local isNear = false

            for _, point in ipairs(points) do
                local dx, dy, dz = location.X - point.x, location.Y - point.y, location.Z - point.z

                if dx * dx + dy * dy + dz * dz <= point.r * point.r then
                    isNear = true
                    break
                end
            end

            if not isNear then
                return
            end

            local uid = mediator:GetGUID(npc)

            if type(uid) == "number" and uid ~= 0 then
                consoleManager:XApplyEffectOnNPCByUID("MolotovBurning", uid)
                applied = applied + 1
            end
        end)
    end

    if tag then
        Unreal.log(string.format("%s: MolotovBurning applied to %d NPC(s)", tag, applied))
    end
end

function GroundFire.igniteNearby(x, y, z)
    burnNPCsNear({ { x = x, y = y, z = z, r = BURN_RADIUS } }, "ignite")
end

-- The pool keeps burning what stands in it. Without this, env-fire patches only ever
-- burn the PLAYER (vanilla BurnTriggerCollider behavior) — mutants walked through the
-- fire unfazed because the initial 15s burn can't outrun their 5%/s regen. KeepNew on
-- the effect means each 1s pass just refreshes duration while they linger.
local function refreshPoolBurns()
    local points = {}

    for _, fire in ipairs(fires) do
        if Unreal.isAlive(fire.actor) then
            pcall(function()
                local location = fire.actor:K2_GetActorLocation()
                points[#points + 1] = { x = location.X, y = location.Y, z = location.Z, r = POOL_BURN_RADIUS }
            end)
        end
    end

    if #points == 0 then
        return
    end

    local now = os.clock()
    local tag = now >= poolLogAt and "pool" or nil

    if tag then
        poolLogAt = now + 5 -- at most one report per 5s
    end

    burnNPCsNear(points, tag)
end

-- Extinguish expired fires; while any burn, keep NPCs standing in the pool alight.
function GroundFire.start()
    LoopInGameThreadWithDelay(1000, function()
        if #fires == 0 then
            return false
        end

        ExecuteInGameThread(function()
            for fireIndex = #fires, 1, -1 do
                local fire = fires[fireIndex]

                if os.clock() >= fire.dieAt or not Unreal.isAlive(fire.actor) then
                    if Unreal.isAlive(fire.actor) then
                        pcall(function()
                            fire.actor:K2_DestroyActor()
                        end)
                    end

                    table.remove(fires, fireIndex)
                end
            end

            if #fires > 0 then
                pcall(refreshPoolBurns)
            end
        end)

        return false
    end)
end

return GroundFire
