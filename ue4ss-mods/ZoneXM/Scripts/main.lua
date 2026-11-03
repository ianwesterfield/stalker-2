-- Zone XM — conversation awareness for external music.
-- Danger = gunfire near Skif. Live-fire test 2026-11-02: of 7 candidates
-- (OnDamageReceived_BP, OnShot_BP, OnShootingStarted_BP, OnFirePressed[_BP],
-- ShootingWeaponComponent:Shoot, OnShotSoundStart) exactly ONE crosses the
-- script VM: ItemAppearanceComponent:OnShotSoundStart — one dispatch per shot,
-- player and NPC weapons alike. Fire-rate-bounded. Radius-gated via the
-- component's owning weapon actor (attached = wielder position).
-- If the watchdog is down, this is inert.
local UEHelpers = require("UEHelpers")
local function log(msg) print("[ZoneXM] " .. msg .. "\n") end

local FLAG_DIR = os.getenv("LOCALAPPDATA") .. "\\Stalker2\\Saved\\ZoneXM"
-- no os.execute here: cmd flash at boot stole game input capture (mouse stuck till menu toggle);
-- the watchdog creates this dir, and writeFlag just no-ops until it exists
local FLAG = FLAG_DIR .. "\\alert.flag"

local POLL_MS = 250
local HOLDOFF_MS = 6000      -- flag stays hot this long after the last hit
local HEARTBEAT_MS = 3000    -- watchdog treats a flag older than 8s as a dead game
local DANGER_RADIUS = 6000   -- cm; hits beyond this aren't your fight

local lastHitAt = 0.0        -- wall ms; written by hooks, read by the poll
local hitCount = 0

local function nearPlayer(who)
    local pawn, ploc
    pcall(function() pawn = UEHelpers.GetPlayerController().Pawn end)
    if not (pawn and pawn:IsValid()) then return false end
    pcall(function() ploc = pawn:K2_GetActorLocation() end)
    if not ploc then return true end   -- can't measure = assume it matters
    local l
    pcall(function() l = who:K2_GetActorLocation() end)
    if not l then pcall(function() l = who:GetOwner():K2_GetActorLocation() end) end  -- components
    if not l then return true end      -- unlocatable dispatcher: assume it's your fight
    local dx, dy, dz = l.X - ploc.X, l.Y - ploc.Y, l.Z - ploc.Z
    return dx * dx + dy * dy + dz * dz <= DANGER_RADIUS * DANGER_RADIUS
end

local hitFns = {
    "/Script/Stalker2.ItemAppearanceComponent:OnShotSoundStart", -- the ONE proven VM dispatch
    -- Dead (never dispatch through the VM, proven by live fire): OnDamageReceived_BP,
    -- OnShot_BP, OnShootingStarted_BP, OnFirePressed[_BP], ShootingWeaponComponent:Shoot.
    -- Obj:OnHit is OUT: per-physics-contact on characters; pegged the game thread.
}
local rawByFn = {}
for _, fn in ipairs(hitFns) do
    local short = fn:match(":([^:]+)$")
    local ok, err = pcall(function()
        RegisterHook(fn, function(self)
            pcall(function()
                local n = (rawByFn[short] or 0) + 1
                rawByFn[short] = n
                if n <= 3 then log(short .. " fired raw (#" .. n .. ")") end
                local who = self:get()
                if who and nearPlayer(who) then
                    lastHitAt = os.time() * 1000
                    hitCount = hitCount + 1
                    if hitCount <= 3 then log("combat near Skif (#" .. hitCount .. ") via " .. short) end
                end
            end)
        end)
    end)
    log("hook " .. short .. (ok and " armed" or (" FAILED: " .. tostring(err))))
end

local lastBeatAt = 0.0
local written = nil          -- nil = no file written this session yet
local writes = 0

local function writeFlag()
    local f = io.open(FLAG, "w")
    if f then f:write(tostring(os.time())) f:close() end
end

LoopAsync(POLL_MS, function()
    local nowMs = os.time() * 1000
    -- lastHitAt's window IS the holdoff (the old two-layer version doubled it)
    local hot = lastHitAt > 0 and (nowMs - lastHitAt) < HOLDOFF_MS
    if hot then
        -- beat stamp only on actual writes, else the heartbeat never fires
        if not written or nowMs - lastBeatAt >= HEARTBEAT_MS then
            writeFlag()
            lastBeatAt = nowMs
            if not written then writes = writes + 1 end
        end
    elseif written then
        pcall(os.remove, FLAG)
        writes = writes + 1
    end
    if writes <= 4 and hot ~= written then log("alert -> " .. (hot and "DANGER" or "clear")) end
    written = hot
    return false
end)

log("loaded (flag: " .. FLAG .. ")")
