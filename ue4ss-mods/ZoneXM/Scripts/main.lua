-- Zone XM — conversation awareness for external music.
-- Reads Skif's threat state (Agent:IsInThreat — the compass-red source) and mirrors
-- it to a flag file; the watchdog (tools/zonexm-watchdog.ps1) ducks the music app's
-- Windows audio session while the flag says danger. Game audio is never touched.
-- If the watchdog is down, this is inert.
local function log(msg) print("[ZoneXM] " .. msg .. "\n") end

local FLAG_DIR = os.getenv("LOCALAPPDATA") .. "\\Stalker2\\Saved\\ZoneXM"
os.execute('mkdir "' .. FLAG_DIR .. '" 2>nil')
local FLAG = FLAG_DIR .. "\\alert.flag"

local POLL_MS = 250
local HOLDOFF_MS = 4000      -- flag stays hot briefly after the compass clears
local HEARTBEAT_MS = 3000    -- watchdog treats a flag older than 8s as a dead game

local lastDangerAt = 0.0     -- os.time()*1000: wall clock (os.clock is CPU time)
local lastBeatAt = 0.0
local written = nil          -- nil = no file written this session yet
local writes = 0

local function writeFlag()
    local f = io.open(FLAG, "w")
    if f then f:write(tostring(os.time())) f:close() end
end

LoopAsync(POLL_MS, function()
    local danger = false
    local nowMs = os.time() * 1000
    ExecuteInGameThread(function()
        pcall(function()
            local pawn = UEHelpers.GetPlayerController().Pawn
            if pawn and pawn:IsValid() and pawn.IsA and pawn:IsA("/Script/Stalker2.Obj") then
                danger = pawn:IsInThreat() == true
            end
        end)
    end)
    if danger then lastDangerAt = nowMs end
    local hot = danger or (nowMs - lastDangerAt < HOLDOFF_MS)
    if hot then
        if not written then writeFlag() writes = writes + 1
        elseif nowMs - lastBeatAt >= HEARTBEAT_MS then writeFlag() end
        lastBeatAt = nowMs
    elseif written then
        pcall(os.remove, FLAG)
        writes = writes + 1
    end
    if writes <= 4 and hot ~= written then log("alert -> " .. (hot and "DANGER" or "clear")) end
    written = hot
    return false
end)

log("loaded (flag: " .. FLAG .. ")")
