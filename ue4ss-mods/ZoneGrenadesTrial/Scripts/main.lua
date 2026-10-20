-- ZoneGrenadesTrial: F7 spawns one batch of every ZoneGrenades (Nexus mod 2913) grenade.
-- Temporary trial helper while MolotovFire is disabled. No hooks, no tick work.

local function log(msg)
    print("[ZoneGrenadesTrial] " .. tostring(msg) .. "\n")
end

-- SIDs published on the mod page (v0.4.0 BETA)
local GRENADE_SIDS = {
    "ZoneGrenadeSmoke",
    "ZoneGrenadeFlash",
    "ZoneGrenadeMolotov",
    "ZoneGrenadeGas",
    "ZoneGrenadeNoise",
    "ZoneGrenadeImpact",
}

local function liveInstance(className)
    local all = FindAllOf(className)
    if all then
        for _, o in ipairs(all) do
            -- skip the CDO: calling spawn helpers on it null-derefs (no world)
            if o:IsValid() and not o:GetFullName():find("Default__") then return o end
        end
    end
    return nil
end

RegisterKeyBind(Key.F7, function()
    ExecuteInGameThread(function()
        log("F7 pressed - spawning ZoneGrenades set")
        local rk = liveInstance("CustomConsoleManagerRK")
        if not rk then
            log("no live CustomConsoleManagerRK (not in a level yet?)")
            return
        end
        for _, sid in ipairs(GRENADE_SIDS) do
            local ok, err = pcall(function() rk:XCreateItemInInventoryByID(sid, 0, 3, 1.0) end)
            log("XCreateItemInInventoryByID " .. sid .. " x3 -> " .. (ok and "called" or tostring(err)))
        end
    end)
end)

log("loaded - F7 = 3x of each ZoneGrenades grenade into inventory")
