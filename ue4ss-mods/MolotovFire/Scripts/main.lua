local function log(msg) print("[MolotovFire] " .. msg .. "\n") end

log("loaded")

-- Track live grenades; a vanished actor's last position = detonation site.
local tracked = {}
local trackedCount = 0

NotifyOnNewObject("/Game/GameLite/Blueprints/Grenades/BP_grenade.BP_Grenade_C", function(grenade)
    local ok, name = pcall(function() return grenade:GetFullName() end)
    tracked[#tracked + 1] = { actor = grenade, x = 0, y = 0, z = 0, alive = true }
    trackedCount = trackedCount + 1
    log("grenade spawned: " .. (ok and name or "?"))
end)

LoopAsync(100, function()
    if trackedCount == 0 then return false end
    ExecuteInGameThread(function()
        for _, t in ipairs(tracked) do
            if t.alive then
                local ok = pcall(function()
                    if t.actor:IsValid() then
                        local loc = t.actor:K2_GetActorLocation()
                        t.x, t.y, t.z = loc.X, loc.Y, loc.Z
                    else
                        t.alive = false
                        trackedCount = trackedCount - 1
                        log(string.format("DETONATION at %.0f %.0f %.0f", t.x, t.y, t.z))
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

-- F6: probe which classes are loaded; groundwork for spawning ground fire.
RegisterKeyBind(Key.F6, function()
    ExecuteInGameThread(function()
        log("F6 class probe")
        local candidates = {
            "/Game/GameLite/Blueprints/Grenades/BP_grenade.BP_Grenade_C",
            "/Game/GameLite/Blueprints/Anomalies/BP_ClassicFireAnomaly.BP_ClassicFireAnomaly_C",
            "/Game/GameLite/Blueprints/Anomalies/BP_FireBallAnomaly.BP_FireBallAnomaly_C",
        }
        for _, path in ipairs(candidates) do
            local obj = StaticFindObject(path)
            log(path .. " -> " .. ((obj and obj:IsValid()) and "LOADED" or "not loaded"))
        end
        local grenades = FindAllOf("BP_Grenade_C")
        log("live BP_Grenade_C instances: " .. (grenades and #grenades or 0))
    end)
end)
