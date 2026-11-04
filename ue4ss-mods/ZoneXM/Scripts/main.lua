-- Zone XM — conversation awareness for external music.
-- Ducks for the sounds of people AND the things that hunt them: gunfire near
-- Skif, dialogue, nearby voices, and mutants inside his AI sphere (dogs don't
-- announce themselves — the gunfire tier is deaf to teeth).
-- Gunfire: ItemAppearanceComponent:OnShotSoundStart (sole VM dispatch of 7).
-- Dialogue: PC:IsInStaticDialog polled — queryable, zero patch risk.
-- Voices/melee: notify batteries under live test (prune like the gun tier).
-- Mutants: FindAllOf(AnimInstanceMutant) sweep — only spawned mutants animate,
-- IsAlive filters corpses. No property reflection (that's what pegged zxprobe).
-- If the watchdog is down, this is inert.
local UEHelpers = require("UEHelpers")
local function log(msg) print("[ZoneXM] " .. msg .. "\n") end

assert(type(LoopInGameThreadWithDelay) == "function",
    "ZoneXM requires UE4SS LoopInGameThreadWithDelay")

local FLAG_DIR = os.getenv("LOCALAPPDATA") .. "\\Stalker2\\Saved\\ZoneXM"
-- no os.execute here: cmd flash at boot stole game input capture (mouse stuck till menu toggle);
-- the watchdog creates this dir, and writeFlag just no-ops until it exists
local FLAG = FLAG_DIR .. "\\alert.flag"

local POLL_MS = 250
local HOLDOFF_MS = 6000      -- gunfire keeps the flag hot this long after the last shot
local TALK_HOLDOFF_MS = 2500 -- voices get a shorter tail (conversation ends = music back)
local HEARTBEAT_MS = 3000    -- watchdog treats a flag older than 8s as a dead game
local DANGER_RADIUS = 6000   -- cm; sounds beyond this aren't your scene
local BEAST_RADIUS = 3500    -- cm; a live mutant this close = duck NOW
local BEAST_HOLDOFF_MS = 3000  -- radar self-refreshes while they linger; short tail
local BEAST_SWEEP_MS = 750   -- radar cadence (lighter than the flag poll)

local lastHitAt = 0.0        -- wall ms; written by hooks, read by the poll
local lastTalkAt = 0.0
local lastBeastAt = 0.0
local hitCount = 0
local talkCount = 0
local beastCount = 0

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

local rawByFn = {}
local function armBattery(fns, onNear)
    for _, fn in ipairs(fns) do
        local short = fn:match(":([^:]+)$")
        local ok, err = pcall(function()
            RegisterHook(fn, function(self)
                local fired = pcall(function()
                    local who = self:get()
                    if not (who and who:IsValid()) then return end
                    local n = (rawByFn[short] or 0) + 1
                    rawByFn[short] = n
                    if n <= 3 then log(short .. " fired raw (#" .. n .. ")") end
                    if nearPlayer(who) then onNear(short) end
                end)
            end)
        end)
        log("hook " .. short .. (ok and " armed" or (" FAILED: " .. tostring(err))))
    end
end

armBattery({
    "/Script/Stalker2.ItemAppearanceComponent:OnShotSoundStart", -- the ONE proven VM dispatch
    -- Dead (never dispatch through the VM, proven by live fire): OnDamageReceived_BP,
    -- OnShot_BP, OnShootingStarted_BP, OnFirePressed[_BP], ShootingWeaponComponent:Shoot.
    -- Obj:OnHit is OUT: per-physics-contact on characters; pegged the game thread.
}, function(short)
    lastHitAt = os.time() * 1000
    hitCount = hitCount + 1
    if hitCount <= 3 then log("combat near Skif (#" .. hitCount .. ") via " .. short) end
end)

armBattery({
    "/Script/Stalker2.Obj:OnMeleeAttack_BP",  -- the lunge itself (candidate; attack-rate-bounded)
    "/Script/Stalker2.Obj:MakeAttack_BP",
    -- Dead voice candidates (armed, never fired through live chatter + a dialog):
    -- CppMediator:CreateAIVoiceEvent, SoundWaveSpeechComponent:OnVoicegenFinished.
    -- Speech detection lives in the poll now: SubtitleView visibility.
}, function(short)
    lastBeastAt = os.time() * 1000
    beastCount = beastCount + 1
    if beastCount <= 3 then log("melee near Skif (#" .. beastCount .. ") via " .. short) end
end)

-- mutant radar: anything with a mutant anim instance, alive, inside the sphere
local radarLogs = 0
LoopInGameThreadWithDelay(BEAST_SWEEP_MS, function()
    pcall(function()
        local pawn = UEHelpers.GetPlayerController().Pawn
        if not (pawn and pawn:IsValid()) then return end
        local ploc = pawn:K2_GetActorLocation()
        local insts = FindAllOf("AnimInstanceMutant") or {}
        local found = false
        for _, inst in ipairs(insts) do
            pcall(function()
                local beast = inst:GetOwningActor()
                if beast and beast:IsValid() and beast:IsAlive() then
                    local l = beast:K2_GetActorLocation()
                    local dx, dy, dz = l.X - ploc.X, l.Y - ploc.Y, l.Z - ploc.Z
                    local d2 = dx * dx + dy * dy + dz * dz
                    if d2 <= BEAST_RADIUS * BEAST_RADIUS then
                        lastBeastAt = os.time() * 1000
                        found = true
                        if radarLogs < 3 then
                            radarLogs = radarLogs + 1
                            log(string.format("beast in sphere: %s at %.0fm", beast:GetClass():GetFName():ToString(), math.sqrt(d2) / 100))
                        end
                    end
                end
            end)
            if found then break end  -- one live beast is enough this sweep
        end
    end)
    return false
end)

local lastBeatAt = 0.0
local written = nil          -- nil = no file written this session yet
local writes = 0
local dialogProbe = false    -- log the IsInStaticDialog verdict once

local function writeFlag()
    local f = io.open(FLAG, "w")
    if f then f:write(tostring(os.time())) f:close() end
end

LoopInGameThreadWithDelay(POLL_MS, function()
    local nowMs = os.time() * 1000
    -- speech tier: subtitles render whenever anyone talks (dialogs, barks,
    -- cutscenes) — requires subtitles ON in game settings. IsInStaticDialog
    -- stayed false through a real dialog (first test) but costs nothing.
    pcall(function()
        local sv = FindFirstOf("SubtitleView")
        if sv and sv:IsValid() and sv:IsVisible() then
            lastTalkAt = nowMs
            talkCount = talkCount + 1
            if talkCount <= 3 then log("subtitles visible: someone's talking (#" .. talkCount .. ")") end
        end
    end)
    local pcAlive = false
    pcall(function()
        local pc = UEHelpers.GetPlayerController()
        pcAlive = pc and pc:IsValid() or false
        if pcAlive and pc:IsInStaticDialog() then
            lastTalkAt = nowMs
            if not dialogProbe then log("static dialog detected (queryable works)") dialogProbe = true end
        end
    end)
    -- Loading / world transition: no player controller = nothing is near Skif.
    if not pcAlive then
        lastHitAt, lastTalkAt, lastBeastAt = 0.0, 0.0, 0.0
    end
    -- lastHitAt's window IS the holdoff (the old two-layer version doubled it)
    local hot = (lastHitAt > 0 and (nowMs - lastHitAt) < HOLDOFF_MS)
        or (lastTalkAt > 0 and (nowMs - lastTalkAt) < TALK_HOLDOFF_MS)
        or (lastBeastAt > 0 and (nowMs - lastBeastAt) < BEAST_HOLDOFF_MS)
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
