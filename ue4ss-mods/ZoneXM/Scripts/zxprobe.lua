-- zxprobe.lua v4 — listen to the game's own music brain.
--
-- Run:  dofile("ue4ss/Mods/ZoneXM/Scripts/zxprobe.lua")
-- Then: idle ~5s, get the compass red, fight, withdraw. 45s window.
--
-- Hooks Wwise: AkGameplayStatics:SetState is THE classic combat-music driver
-- (state group + state name per call). PostEvent filtered to music/combat-ish
-- event names. Zero polling — every line is an event fired by the game.

local function log(msg) print("[zxprobe] " .. msg .. "\n") end
log("armed v4 - idle, then fight (45s)")

local function paramStr(p)
    local out
    pcall(function()
        local v = p and p.get and p:get() or p
        if type(v) == "userdata" then
            pcall(function()
                if v.ToString then out = v:ToString() end
            end)
            if not out then pcall(function() out = v:GetFullName() end) end
        end
        out = out or tostring(v)
    end)
    return out
end

local okState = pcall(function()
    RegisterHook("/Script/AkAudio.AkGameplayStatics:SetState", function(self, a, b)
        pcall(function()
            log(string.format("SetState: %s | %s", tostring(paramStr(a)), tostring(paramStr(b))))
        end)
    end)
end)
log("SetState hook: " .. (okState and "armed" or "FAILED"))

local okPost = pcall(function()
    RegisterHook("/Script/AkAudio.AkGameplayStatics:PostEvent", function(self, event)
        pcall(function()
            local n = paramStr(event)
            if n and n:lower():find("combat") or (n and n:lower():find("music"))
                    or (n and n:lower():find("battle")) or (n and n:lower():find("danger")) then
                log("PostEvent: " .. tostring(n))
            end
        end)
    end)
end)
log("PostEvent hook: " .. (okPost and "armed" or "FAILED"))

local ticks = 0
LoopAsync(500, function()
    ticks = ticks + 1
    if ticks >= 90 then log("probe window over") return true end
    return false
end)
