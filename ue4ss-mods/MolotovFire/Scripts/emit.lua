-- live Niagara emitter A/B on the lit rag fire; run from UE4SS console:
--   EMIT="smoke_4" EN=0 dofile("ue4ss/Mods/MolotovFire/Scripts/emit.lua")
--   EMIT="all" EN=0 dofile(...)          -- kill every emitter (sanity: card must die)
--   dofile(...)                          -- no vars = just report component state
local target = EMIT or ""
local enable = (tonumber(EN) or 0) ~= 0
local NAMES = { "embers001_1", "fire001_1", "NiagaraEmitter_2", "smoke_4" }
ExecuteInGameThread(function()
    local comps = FindAllOf("NiagaraComponent") or {}
    local found = 0
    for _, c in ipairs(comps) do
        local hit = false
        pcall(function()
            if not c:IsValid() then return end
            local a = c:GetAsset()
            hit = a and a:IsValid()
                and a:GetFullName():find("NS_Character_Fire", 1, true) ~= nil
        end)
        if hit then
            found = found + 1
            local act, solo = "?", "?"
            pcall(function() act = tostring(c:IsActive()) end)
            pcall(function() solo = tostring(c:GetForceSolo()) end)
            print(string.format("[emit] %s active=%s solo=%s\n", c:GetFullName(), act, solo))
            local list = (target == "all") and NAMES or { target }
            for _, en in ipairs(list) do
                if en ~= "" then
                    local ok, err = pcall(function() c:SetEmitterEnable(FName(en), enable) end)
                    print(string.format("[emit] %s -> %s : %s\n",
                        en, tostring(enable), ok and "ok" or tostring(err)))
                end
            end
        end
    end
    if found == 0 then print("[emit] no NS_Character_Fire component (light the rag first)\n") end
end)
