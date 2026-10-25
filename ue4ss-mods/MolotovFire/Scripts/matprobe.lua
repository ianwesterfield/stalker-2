-- identify the cooked generation of the flame mats on the in-hand bottle:
--   dofile("ue4ss/Mods/MolotovFire/Scripts/matprobe.lua")
-- reads PARENT material defaults (MID overrides don't apply): OpacityBoost 0.0
-- = fresh 7:07 cook, 2.5 = stale 4:36 cook, SheathIntensity/FlipbookFPS != 0
-- = ancient 10/23 sheath-era cook
ExecuteInGameThread(function()
    local comps = FindAllOf("SkeletalMeshComponent") or {}
    local found = 0
    for _, c in ipairs(comps) do
        local hit = false
        pcall(function()
            if not c:IsValid() then return end
            local a = c:GetSkeletalMeshAsset()
            hit = a and a:IsValid()
                and a:GetFullName():find("SK_MolotovBottle", 1, true) ~= nil
        end)
        if hit then
            found = found + 1
            for i = 3, 4 do
                local m = c:GetMaterial(i)
                if m and m:IsValid() then
                    local parent = nil
                    pcall(function() parent = m.Parent end)
                    local tgt = (parent and parent:IsValid()) and parent or m
                    print(string.format("[matprobe] slot %d: %s\n", i, tgt:GetFullName()))
                    for _, pn in ipairs({ "OpacityBoost", "OpacityPower", "FireIntensity",
                                          "FireDepthFade", "DebugUV", "SheathIntensity",
                                          "FlipbookFPS", "SheathDepthFade" }) do
                        local got = false
                        pcall(function()
                            local v = tgt:K2_GetScalarParameterValue(FName(pn))
                            print(string.format("[matprobe]   %s = %.3f\n", pn, v))
                            got = true
                        end)
                        if not got then
                            pcall(function()
                                local v = tgt:GetScalarParameterValue(FName(pn))
                                print(string.format("[matprobe]   %s = %.3f\n", pn, v))
                            end)
                        end
                    end
                    pcall(function() print(string.format("[matprobe]   BlendMode = %d\n", tgt.BlendMode)) end)
                    pcall(function() print(string.format("[matprobe]   bUseMaterialAttributes = %s\n", tostring(tgt.bUseMaterialAttributes))) end)
                    pcall(function() print(string.format("[matprobe]   bUsedWithSkeletalMesh = %s\n", tostring(tgt.bUsedWithSkeletalMesh))) end)
                end
            end
        end
    end
    if found == 0 then print("[matprobe] no SK_MolotovBottle comp found (equip it first)\n") end
end)
