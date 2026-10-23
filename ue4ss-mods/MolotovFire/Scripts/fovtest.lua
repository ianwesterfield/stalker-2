-- fovtest.lua v2 - inspect MIDs + toggle ForegroundFOVEnabled.
-- FOVLIST() lists unique MID parents; FOVLIST("text") filters.
-- FOVTEST(v, "filter") sets param on MIDs whose parent OR own name matches.
local function midName(mid)
    local ok, s = pcall(function() return mid:GetFullName() end)
    return ok and s or "?"
end

local function parentName(mid)
    local ok, p = pcall(function() return mid.Parent end)
    if ok and p and p.IsValid and p:IsValid() then
        local ok2, s = pcall(function() return p:GetFullName() end)
        if ok2 then return s end
    end
    return "<no parent>"
end

FOVLIST = function(filter)
    local mids = FindAllOf("MaterialInstanceDynamic")
    if not mids then print("[fovtest] no MIDs\n") return end
    local seen = {}
    local total = 0
    for _, mid in ipairs(mids) do
        if mid:IsValid() then
            total = total + 1
            local pn = parentName(mid)
            if (not filter) or pn:find(filter) or midName(mid):find(filter) then
                seen[pn] = (seen[pn] or 0) + 1
            end
        end
    end
    for pn, c in pairs(seen) do
        print(string.format("[fovtest] x%d parent: %s\n", c, pn))
    end
    print(string.format("[fovtest] %d valid MIDs total\n", total))
end

FOVTEST = function(v, filter)
    filter = filter or "RagFlame"
    local mids = FindAllOf("MaterialInstanceDynamic")
    if not mids then print("[fovtest] no MIDs\n") return end
    local n = 0
    for _, mid in ipairs(mids) do
        if mid:IsValid() then
            local pn = parentName(mid)
            if pn:find(filter) or midName(mid):find(filter) then
                mid:SetScalarParameterValue(FName("ForegroundFOVEnabled"), v)
                n = n + 1
                print(string.format("[fovtest] %s -> %.1f\n", pn, v))
            end
        end
    end
    print(string.format("[fovtest] updated %d MIDs matching '%s'\n", n, filter))
end

print("[fovtest] v2 loaded - FOVLIST('Rag') / FOVLIST('Molotov') / FOVLIST(); FOVTEST(0,'RagFlame')\n")
