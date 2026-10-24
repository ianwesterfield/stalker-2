-- hide/show one material slot's geometry on the in-hand bottle (UE4SS console):
--   SLOT=2 SHOW=0 dofile("ue4ss/Mods/MolotovFire/Scripts/hide.lua")   -- hide rag
--   SLOT=2 SHOW=1 dofile("ue4ss/Mods/MolotovFire/Scripts/hide.lua")   -- restore
-- slots: 0=glass(+phys helpers) 1=label 2=MolotovRag 3=RagFlame(cap) 4=SheathFlame
local slot = tonumber(SLOT) or 2
local show = (tonumber(SHOW) or 0) ~= 0
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
            local ok, err = pcall(function()
                c:ShowMaterialSection(slot, 0, show, 0)
            end)
            print(string.format("[hide] %s slot %d show=%s ok=%s %s\n",
                c:GetFullName(), slot, tostring(show), tostring(ok), err or ""))
        end
    end
    if found == 0 then print("[hide] no SK_MolotovBottle comp found (equip it first)\n") end
end)
