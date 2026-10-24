-- live scalar-param A/B on the in-hand bottle; run from UE4SS console:
--   DROOP=0.0 dofile("ue4ss/Mods/MolotovFire/Scripts/droop.lua")
--   PARAM="BurnGlow" VAL=1.2 dofile("ue4ss/Mods/MolotovFire/Scripts/droop.lua")
local pname = PARAM or "DroopStrength"
local value = tonumber(VAL) or tonumber(DROOP) or 0.0
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
            print("[droop] " .. c:GetFullName() .. "\n")
            local n = c:GetNumMaterials()
            for i = 0, n - 1 do
                local m = c:GetMaterial(i)
                local fn = (m and m:IsValid()) and m:GetFullName() or "nil"
                print(string.format("[droop] slot %d = %s\n", i, fn))
                if fn:find("MolotovRag", 1, true) or fn:find("RagFlame", 1, true) then
                    local mid = c:CreateDynamicMaterialInstance(i, m, FName("None"))
                    if mid and mid:IsValid() then
                        mid:SetScalarParameterValue(FName(pname), value)
                        print(string.format("[droop] slot %d -> %s=%.2f\n", i, pname, value))
                    end
                end
            end
        end
    end
    if found == 0 then print("[droop] no SK_MolotovBottle comp found (equip it first)\n") end
end)
