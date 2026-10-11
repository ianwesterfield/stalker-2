local function log(msg) print("[MolotovFire] " .. msg .. "\n") end

log("loaded")

local UEHelpers = require("UEHelpers")

local FIRE_CLASS_PATH = "/Game/GameLite/Blueprints/Anomalies/BP_ClassicFireAnomaly.BP_ClassicFireAnomaly_C"
local FIRE_SECONDS = 20          -- ground burns this long
local FIRE_COUNT = 3             -- patches per detonation (coverage)
local FIRE_SPREAD = 220          -- cm offset ring around impact

-- Track live grenades; a vanished actor's last position = detonation site.
local tracked = {}
local trackedCount = 0
local fires = {}                 -- { actor, dieAt }

local function spawnGroundFire(x, y, z)
    local fireClass = StaticFindObject(FIRE_CLASS_PATH)
    if not (fireClass and fireClass:IsValid()) then
        fireClass = LoadAsset(FIRE_CLASS_PATH)
    end
    if not (fireClass and fireClass:IsValid()) then
        log("FIRE: class failed to load")
        return
    end
    local gs = StaticFindObject("/Script/Engine.Default__GameplayStatics")
    local world = UEHelpers.GetWorld()
    if not (gs and gs:IsValid() and world and world:IsValid()) then
        log("FIRE: no GameplayStatics/world")
        return
    end
    local spawned = 0
    for i = 1, FIRE_COUNT do
        -- first patch dead center, rest on a ring
        local ang = math.random() * 2 * math.pi
        local dist = (i == 1) and 0 or (FIRE_SPREAD * (0.6 + 0.4 * math.random()))
        local transform = {
            Rotation = { X = 0, Y = 0, Z = 0, W = 1 },
            Translation = { X = x + math.cos(ang) * dist, Y = y + math.sin(ang) * dist, Z = z },
            Scale3D = { X = 1, Y = 1, Z = 1 },
        }
        local ok, err = pcall(function()
            local actor = gs:BeginDeferredActorSpawnFromClass(world, fireClass, transform, 1, nil)
            if actor and actor:IsValid() then
                gs:FinishSpawningActor(actor, transform)
                fires[#fires + 1] = { actor = actor, dieAt = os.clock() + FIRE_SECONDS }
                spawned = spawned + 1
            end
        end)
        if not ok then log("FIRE spawn error: " .. tostring(err)) end
    end
    log(string.format("FIRE: %d patches burning at %.0f %.0f %.0f", spawned, x, y, z))
end

-- Extinguish expired fires.
LoopAsync(1000, function()
    if #fires == 0 then return false end
    ExecuteInGameThread(function()
        for i = #fires, 1, -1 do
            local f = fires[i]
            if os.clock() >= f.dieAt then
                pcall(function()
                    if f.actor:IsValid() then f.actor:K2_DestroyActor() end
                end)
                table.remove(fires, i)
            end
        end
    end)
    return false
end)

NotifyOnNewObject("/Game/GameLite/Blueprints/Grenades/BP_grenade.BP_Grenade_C", function(grenade)
    tracked[#tracked + 1] = { actor = grenade, x = 0, y = 0, z = 0, alive = true, seen = 0 }
    trackedCount = trackedCount + 1
    log("grenade spawned (equipped)")
end)

LoopAsync(100, function()
    if trackedCount == 0 then return false end
    ExecuteInGameThread(function()
        for _, t in ipairs(tracked) do
            if t.alive then
                local ok = pcall(function()
                    if t.actor:IsValid() then
                        local loc = t.actor:K2_GetActorLocation()
                        if (loc.X == 0 and loc.Y == 0 and loc.Z == 0) then
                            local root = t.actor.RootComponent
                            if root and root:IsValid() then
                                loc = root:K2_GetComponentLocation()
                            end
                        end
                        -- grenade parks at origin while equipped; only record real positions
                        if not (loc.X == 0 and loc.Y == 0 and loc.Z == 0) then
                            t.x, t.y, t.z = loc.X, loc.Y, loc.Z
                            t.seen = (t.seen or 0) + 1
                            if t.seen % 10 == 1 then
                                log(string.format("tracking %.0f %.0f %.0f", t.x, t.y, t.z))
                            end
                        end
                    else
                        t.alive = false
                        trackedCount = trackedCount - 1
                        log(string.format("DETONATION at %.0f %.0f %.0f (reads=%d)", t.x, t.y, t.z, t.seen or 0))
                        -- seen>=2 = it actually flew; equip-cycling despawns have zero reads
                        if (t.seen or 0) >= 2 then
                            spawnGroundFire(t.x, t.y, t.z)
                        end
                    end
                end)
                if not ok and t.alive then
                    t.alive = false
                    trackedCount = trackedCount - 1
                    log(string.format("DETONATION (err path) at %.0f %.0f %.0f", t.x, t.y, t.z))
                end
            end
        end
    end)
    return false
end)

-- F6: probe/load the fire class without needing a throw.
RegisterKeyBind(Key.F6, function()
    ExecuteInGameThread(function()
        log("F6 probe")
        local obj = StaticFindObject(FIRE_CLASS_PATH)
        log("StaticFind -> " .. ((obj and obj:IsValid()) and "LOADED" or "nil"))
        if not (obj and obj:IsValid()) then
            obj = LoadAsset(FIRE_CLASS_PATH)
            log("LoadAsset -> " .. ((obj and obj:IsValid()) and "OK" or "FAILED"))
        end
        local pc = UEHelpers.GetPlayerController()
        if obj and obj:IsValid() and pc and pc:IsValid() and pc.Pawn and pc.Pawn:IsValid() then
            local loc = pc.Pawn:K2_GetActorLocation()
            spawnGroundFire(loc.X + 400, loc.Y, loc.Z)   -- test fire 4m ahead-ish
        end
    end)
end)
