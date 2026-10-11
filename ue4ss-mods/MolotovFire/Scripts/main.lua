local function log(msg) print("[MolotovFire] " .. msg .. "\n") end

log("loaded")

local UEHelpers = require("UEHelpers")

local FIRE_CLASS_PATH = "/Game/GameLite/Blueprints/Anomalies/BP_ClassicFireAnomaly.BP_ClassicFireAnomaly_C"

-- One throw = staggered pattern: fire guts out from the edges inward.
-- Burner anomalies take seconds to reach full blaze — short lives read faint.
-- { count, min/max distance (cm), min/max lifetime (s), visual scale }
local RINGS = {
    { count = 1, distMin = 0,   distMax = 0,   lifeMin = 85, lifeMax = 100, scale = 1.4 },  -- heart of the fire
    { count = 4, distMin = 180, distMax = 300, lifeMin = 70, lifeMax = 85,  scale = 1.2 },  -- inner ring
    { count = 5, distMin = 400, distMax = 580, lifeMin = 55, lifeMax = 70,  scale = 1.0 },  -- outer splash
}

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
    for _, ring in ipairs(RINGS) do
        for i = 1, ring.count do
            -- even spacing + jitter reads organic instead of clock-face
            local ang = (i / ring.count) * 2 * math.pi + (math.random() - 0.5)
            local dist = ring.distMin + math.random() * (ring.distMax - ring.distMin)
            local life = ring.lifeMin + math.random() * (ring.lifeMax - ring.lifeMin)
            local transform = {
                Rotation = { X = 0, Y = 0, Z = 0, W = 1 },
                Translation = { X = x + math.cos(ang) * dist, Y = y + math.sin(ang) * dist, Z = z },
                Scale3D = { X = ring.scale, Y = ring.scale, Z = ring.scale },
            }
            local ok, err = pcall(function()
                -- UE 5.5: 6th param = ESpawnActorScaleMethod (1 = MultiplyWithRoot)
                local actor = gs:BeginDeferredActorSpawnFromClass(world, fireClass, transform, 1, nil, 1)
                if actor and actor:IsValid() then
                    gs:FinishSpawningActor(actor, transform)
                    fires[#fires + 1] = { actor = actor, dieAt = os.clock() + life }
                    spawned = spawned + 1
                end
            end)
            if not ok then log("FIRE spawn error: " .. tostring(err)) end
        end
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
                            local okF, errF = pcall(spawnGroundFire, t.x, t.y, t.z)
                            if not okF then log("FIRE handler error: " .. tostring(errF)) end
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

-- F7: prototype-registration oracle — try to conjure molotovs directly.
RegisterKeyBind(Key.F7, function()
    ExecuteInGameThread(function()
        local pc = UEHelpers.GetPlayerController()
        if not (pc and pc:IsValid()) then log("F7: no player controller") return end
        for _, cmd in ipairs({
            "XSpawnItemNearPlayer Vodka 1",
            "XSpawnItemNearPlayer GrenadeMolotov 3",
            "XCreateItemInInventory Vodka 1",
            "XCreateItemInInventory GrenadeMolotov 3",
        }) do
            local ok, err = pcall(function() pc:ConsoleCommand(cmd, false) end)
            log("F7 sent: " .. cmd .. (ok and "" or (" ERR " .. tostring(err))))
        end
    end)
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
