-- Inspect current grenades and watch future spawns; run before equipping.
--   dofile("ue4ss/Mods/MolotovFire/Scripts/worldprobe.lua")
local function inspectActors(actors)
    local smcClass = StaticFindObject("/Script/Engine.StaticMeshComponent")
    local found = 0
    for _, a in ipairs(actors) do
        local actorOk, actorError = pcall(function()
            if not a:IsValid() then return end
            local fn = a:GetFullName()
            if fn:find("Default__", 1, true) then return end
            found = found + 1
            local loc = { X = 0, Y = 0, Z = 0 }
            pcall(function() loc = a:K2_GetActorLocation() end)
            print(string.format("[probe] actor %s @ %.0f,%.0f,%.0f\n",
                fn, loc.X, loc.Y, loc.Z))
            local comps = a:K2_GetComponentsByClass(smcClass)
            if not comps then return end
            for _, componentParam in ipairs(comps) do
                local componentOk, componentError = pcall(function()
                    local c = componentParam:get()
                    if not c:IsValid() then return end
                    local mesh, mname, scale, vis
                    pcall(function()
                        mesh = c.StaticMesh
                        mname = (mesh and mesh:IsValid()) and mesh:GetFullName() or "nil"
                    end)
                    pcall(function()
                        local s = c.RelativeScale3D
                        scale = string.format("%.3f,%.3f,%.3f", s.X, s.Y, s.Z)
                    end)
                    pcall(function() vis = tostring(c:IsVisible()) end)
                    local mn, mx = {}, {}
                    local bounds = "n/a"
                    pcall(function()
                        c:GetLocalBounds(mn, mx)
                        bounds = string.format("%.1f..%.1f %.1f..%.1f %.1f..%.1f",
                            mn.X, mx.X, mn.Y, mx.Y, mn.Z, mx.Z)
                    end)
                    print(string.format("[probe]   comp %s\n    mesh=%s\n    scale=%s vis=%s bounds=%s\n",
                        c:GetFullName(), tostring(mname), tostring(scale),
                        tostring(vis), bounds))
                    local n = c:GetNumMaterials()
                    for i = 0, n - 1 do
                        pcall(function()
                            local m = c:GetMaterial(i)
                            print(string.format("[probe]   slot %d = %s\n", i,
                                (m and m:IsValid()) and m:GetFullName() or "nil"))
                        end)
                    end
                end)
                if not componentOk then
                    print("[probe] component inspection failed: " .. tostring(componentError) .. "\n")
                end
            end
        end)
        if not actorOk then
            print("[probe] actor inspection failed: " .. tostring(actorError) .. "\n")
        end
    end
    if found == 0 then print("[probe] no current grenade; waiting for next equip\n") end
end

WORLDPROBE_INSPECT = inspectActors
if not WORLDPROBE_TABLE_WATCHING then
    NotifyOnNewObject("/Game/GameLite/Blueprints/Grenades/BP_grenade.BP_Grenade_C", function(grenade)
        ExecuteWithDelay(300, function()
            ExecuteInGameThread(function()
                WORLDPROBE_INSPECT({ grenade })
            end)
        end)
    end)
    WORLDPROBE_TABLE_WATCHING = true
end
print("[probe] v3 spawn watch armed - equip a molotov and hold it for one second\n")
ExecuteInGameThread(function()
    inspectActors(FindAllOf("BP_Grenade_C") or {})
end)
