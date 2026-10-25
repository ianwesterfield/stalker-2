-- live Niagara emitter A/B on the lit rag fire; run from UE4SS console:
--   dofile("ue4ss/Mods/MolotovFire/Scripts/emit.lua")   -- report real handle names + state
--   EMIT="smoke" EN=0 dofile(...)                       -- disable one emitter by handle
--   EMIT="all" EN=0 dofile(...)   -- kill every handle (sanity: card MUST die)
local target = EMIT or ""
local enable = (tonumber(EN) or 0) ~= 0
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
            -- real handle names: raw-read the system's EmitterHandles (python-protected,
            -- UE4SS reflection reads it). SetEmitterEnable matches THESE names only.
            local handles = {}
            local okH, errH = pcall(function()
                local arr = c:GetAsset().EmitterHandles
                for i = 1, #arr do
                    local nm, en2 = "?", "?"
                    pcall(function()
                        local h = arr[i]
                        pcall(function() h = h:get() end)
                        pcall(function() nm = h.Name:ToString() end)
                        pcall(function() en2 = tostring(h.bIsEnabled) end)
                    end)
                    if nm ~= "?" then handles[#handles + 1] = nm end
                    print(string.format("[emit] handle %d: %s enabled=%s\n", i, nm, en2))
                end
            end)
            if not okH then print("[emit] EmitterHandles read ERR: " .. tostring(errH) .. "\n") end
            if target ~= "" then
                pcall(function() c:SetForceSolo(true) end)
                pcall(function() solo = tostring(c:GetForceSolo()) end)
                print("[emit] solo now=" .. solo .. "\n")
                local list = (target == "all") and handles or { target }
                for _, en in ipairs(list) do
                    local ok, err = pcall(function() c:SetEmitterEnable(FName(en), enable) end)
                    print(string.format("[emit] %s -> %s : %s\n",
                        en, tostring(enable), ok and "ok" or tostring(err)))
                end
            end
        end
    end
    if found == 0 then print("[emit] no NS_Character_Fire component (light the rag first)\n") end
end)
