-- ZoneLink Tier A build (docs/coop/01-presence.md §7 step 2)
-- Drive stack proven (P-1..P-7). Keys:
--   F2 = record own movement to trace (toggle)  ·  F3 = spawn + protect puppet
--   F4 = cycle drive: OFF -> ESCORT (10m stations) -> GHOST (replay trace) -> OFF
--   F9 = object dump

local function log(msg) print("[ZoneLink] " .. msg .. "\n") end
log("probe build loaded")

local UEHelpers = require("UEHelpers")

local PUPPET_SID = "GeneralNPC_Neutral_Stormtrooper"   -- generic neutral A-Life stalker (P-6)
local NPC_SHORT_CLASS = "BP_AI_Human_C"

local probe = {
    puppet = nil,      -- last spawned actor
    uid = nil,         -- int UID via CppMediator:GetGUID
}

-- Direct-drive state. Tick source: HUD stat panel widget Tick — WeatherController's
-- ReceiveTick exists in reflection but never fires (session 5); widget ticks while HUD is up.
local TICK_HOOK = "/Game/GameLite/FPS_Game/UIRemaster/HUD/StatPanel/W_UpdatedStatPanel.W_UpdatedStatPanel_C:Tick"
local drive = { mode = "off", hooked = false, alive = false, tick = 0,
    lastX = nil, lastY = nil, cmdSpeed = 0, kinematic = false, dt = 1 / 60,
    anim = nil, animLogged = false,
    walkAsset = nil, montage = nil, slotIdx = 1,
    station = nil, stationTimer = 0, stationSpan = 0,
    trace = nil, ghostT = 0, ghostIdx = 1 }

-- Escort stations relative to the player's view yaw; ~10m out on diagonals
local STATIONS = {
    { name = "ahead-left",   f = 700,  r = -700 },
    { name = "ahead-right",  f = 700,  r = 700 },
    { name = "behind-left",  f = -700, r = -700 },
    { name = "behind-right", f = -700, r = 700 },
}

local function pickStation()
    local cur = drive.station
    local nxt
    repeat nxt = STATIONS[math.random(#STATIONS)] until nxt ~= cur
    drive.station = nxt
    drive.stationTimer = 0
    drive.stationSpan = 6 + math.random() * 6
    log("station -> " .. nxt.name)
end

-- Tier A trace: the ghost feed. Same shape a network packet will carry in Tier B.
local TRACE_PATH = "ue4ss/Mods/ZoneLink/ghost-trace.csv"
local REC_HZ = 15
local rec = { active = false, samples = {}, acc = 0, t = 0 }

local function saveTrace()
    local f, err = io.open(TRACE_PATH, "w")
    if not f then log("trace save FAILED: " .. tostring(err)) return end
    f:write("ZLT1\n")
    for _, s in ipairs(rec.samples) do
        f:write(("%.3f %.1f %.1f %.1f %.1f %.1f\n"):format(s.t, s.x, s.y, s.z, s.yaw, s.speed))
    end
    f:close()
    log(("trace saved: %d samples, %.1fs -> %s"):format(#rec.samples, rec.t, TRACE_PATH))
end

local function loadTrace()
    local f = io.open(TRACE_PATH, "r")
    if not f then return nil end
    if f:read("*l") ~= "ZLT1" then f:close() return nil end
    local t = {}
    for line in f:lines() do
        local a, b, c, d, e, g = line:match("^([%-%d%.]+) ([%-%d%.]+) ([%-%d%.]+) ([%-%d%.]+) ([%-%d%.]+) ([%-%d%.]+)$")
        if a then
            t[#t + 1] = { t = tonumber(a), x = tonumber(b), y = tonumber(c), z = tonumber(d),
                yaw = tonumber(e), speed = tonumber(g) }
        end
    end
    f:close()
    if #t < 2 then return nil end
    return t
end

drive.trace = loadTrace()
if drive.trace then
    log(("trace loaded from disk: %d samples, %.1fs"):format(#drive.trace, drive.trace[#drive.trace].t))
end

-- Model stomps StateData every anim update (session 10: gait=ok, anim ignores) — so bypass
-- the gait machine: loop the walk cycle as a dynamic montage through a slot node.
local WALK_ANIM = "/Game/_STALKER2/Animations/Characters/AnimSequences/ar/combat/locomotion/base/stand/AS_tp_ar_combat_walk_fwd.AS_tp_ar_combat_walk_fwd"
local WALK_AUTHORED_SPEED = 180 -- cm/s guess; play rate = cmd/authored, tune by eye
local SLOT_NAMES = { "DefaultSlot", "FullBody", "UpperBody" }

local function ensureMontage(anim, speed)
    if speed > 0 then
        if drive.montage and drive.montage:IsValid() then
            local rate = math.max(0.6, math.min(speed / WALK_AUTHORED_SPEED, 1.8))
            drive.rate = rate
            pcall(function() anim:Montage_SetPlayRate(drive.montage, rate) end)
            return
        end
        if not drive.walkAsset then
            local ok, asset = pcall(function()
                return StaticFindObject(WALK_ANIM) or LoadAsset(WALK_ANIM)
            end)
            if ok and asset and asset:IsValid() then
                drive.walkAsset = asset
            else
                if not drive.assetWarned then drive.assetWarned = true log("montage: walk asset load FAILED") end
                return
            end
        end
        local slot = SLOT_NAMES[drive.slotIdx]
        if not slot then return end -- all slots exhausted
        local okM, m = pcall(function()
            return anim:PlaySlotAnimationAsDynamicMontage(
                drive.walkAsset, FName(slot), 0.25, 0.25, 1.0, 9999, -1.0, 0.0)
        end)
        if okM and m and m:IsValid() then
            drive.montage = m
            log("montage: walk loop STARTED on slot '" .. slot .. "'")
        else
            log("montage: slot '" .. slot .. "' -> " .. (okM and "nil" or tostring(m)) .. ", trying next")
            drive.slotIdx = drive.slotIdx + 1
        end
    elseif drive.montage then
        if drive.montage:IsValid() then
            pcall(function() anim:Montage_Stop(0.25, drive.montage) end)
        end
        drive.montage = nil
        log("montage: stopped (parked)")
    end
end

-- Gait writes target the anim layer: AnimInstanceHuman.StateData (model normally feeds it;
-- our kinematic actor bypasses the model, so StateData keeps saying "stationary").
-- EAnimationStates: 0=None 1=Stand 2=Walking 3=Running 4=Sprinting 5=Crouch 6=LowCrouch 7=Jogging
local function getAnim(a)
    if drive.anim and drive.anim:IsValid() then return drive.anim end
    local ok, anim = pcall(function()
        local mesh = a.Mesh
        if not (mesh and mesh:IsValid()) then return nil end
        return mesh.AnimScriptInstance
    end)
    drive.anim = (ok and anim and anim:IsValid()) and anim or nil
    return drive.anim
end

-- Session 7: CMC accepts Velocity writes (mode 2) but never integrates — its tick is off.
-- Arm it; if the actor still doesn't translate, onTick flips to manual integration.
local function armCMC(a)
    local cmc = a.CharacterMovement
    if not (cmc and cmc:IsValid()) then log("arm: no CharacterMovement") return end
    local okN, cn = pcall(function() return cmc:GetFullName() end)
    log("arm: CMC = " .. (okN and cn or "<name?>"))
    local okT, te = pcall(function() return cmc:IsComponentTickEnabled() end)
    log("arm: tick enabled = " .. tostring(okT and te))
    if okT and te == false then
        local okS = pcall(function() cmc:SetComponentTickEnabled(true) end)
        log("arm: SetComponentTickEnabled(true) -> " .. (okS and "sent" or "ERR"))
    end
end

-- Console dispatcher never fires X-verbs (molotov lesson): call UFunctions on live CCM instances.
local function liveInstance(shortClass)
    local all = FindAllOf(shortClass)
    if all then
        for _, o in ipairs(all) do
            if o:IsValid() and not o:GetFullName():find("Default__") then return o end
        end
    end
    return nil
end

local function fullNameSet()
    local set = {}
    local all = FindAllOf(NPC_SHORT_CLASS)
    if all then
        for _, a in ipairs(all) do
            local ok, fn = pcall(function() return a:GetFullName() end)
            if ok then set[fn] = true end
        end
    end
    return set
end

-- Entity UIDs are native-only on Obj; CppMediator CDO exposes the accessor (GetGUID -> int).
local function getUID(actor)
    local cm = StaticFindObject("/Script/Stalker2.Default__CppMediator")
    if not (cm and cm:IsValid()) then return nil end
    local ok, uid = pcall(function() return cm:GetGUID(actor) end)
    if ok and type(uid) == "number" then return uid end
    return nil
end

-- F3: spawn probe. Dump-verified signature on CustomConsoleManagerRK:
--   XSpawnObjBySID(PrototypeSID, Rank(enum), bDestroyOnOffline, Px, Py, Pz, Pitch, Yaw, Roll)
RegisterKeyBind(Key.F3, function()
    ExecuteInGameThread(function()
        log("F3: spawning " .. PUPPET_SID)
        local rk = liveInstance("CustomConsoleManagerRK")
        if not rk then
            log("F3: no live CustomConsoleManagerRK - be loaded into a save")
            return
        end
        local pc = UEHelpers.GetPlayerController()
        if not (pc and pc:IsValid() and pc.Pawn and pc.Pawn:IsValid()) then
            log("F3: no player pawn")
            return
        end
        local p = pc.Pawn:K2_GetActorLocation()
        local kml = StaticFindObject("/Script/Engine.Default__KismetMathLibrary")
        local rot = pc:GetControlRotation()
        local fwd = kml:GetForwardVector(rot)
        local rightv = kml:GetRightVector(rot)
        -- 5m to a random flank, slightly ahead: easy to observe
        local side = (math.random() < 0.5) and -500 or 500
        local x = p.X + fwd.X * 200 + rightv.X * side
        local y = p.Y + fwd.Y * 200 + rightv.Y * side
        local z = p.Z + 50
        local before = fullNameSet()
        -- bDestroyOnOffline=false: puppet must survive A-Life offline sweeps (P-3)
        local ok, err = pcall(function()
            rk:XSpawnObjBySID(PUPPET_SID, 0, false, x, y, z, 0, 0, 0)
        end)
        log("F3: XSpawnObjBySID -> " .. (ok and "called" or tostring(err)))
        if not ok then return end
        ExecuteWithDelay(700, function()
            ExecuteInGameThread(function()
                local all = FindAllOf(NPC_SHORT_CLASS)
                local fresh = nil
                if all then
                    for _, a in ipairs(all) do
                        local ok, fn = pcall(function() return a:GetFullName() end)
                        if ok and not before[fn] then fresh = a break end
                    end
                end
                if not fresh then
                    log("F3: called OK but no new " .. NPC_SHORT_CLASS ..
                        " after 700ms. Try Rank=1, or check XShowSpawnDebugInfo via CCM")
                    return
                end
                probe.puppet = fresh
                probe.uid = getUID(fresh)
                local okL, loc = pcall(function() return fresh:K2_GetActorLocation() end)
                local okN, fn = pcall(function() return fresh:GetFullName() end)
                log("F3: NEW NPC " .. (okN and fn or "<name?>"))
                if okL and loc then
                    local pc = UEHelpers.GetPlayerController()
                    if pc and pc:IsValid() and pc.Pawn and pc.Pawn:IsValid() then
                        local p = pc.Pawn:K2_GetActorLocation()
                        local d = math.sqrt((loc.X - p.X)^2 + (loc.Y - p.Y)^2 + (loc.Z - p.Z)^2)
                        log(("F3: spawned %.1fm from player"):format(d / 100))
                    end
                end
                log("F3: UID = " .. tostring(probe.uid))
                if probe.uid then
                    local build = liveInstance("CustomConsoleManagerBuild")
                    local ok = build and pcall(function()
                        build:XSetEntityUnkillableByUID(probe.uid, true)
                    end)
                    log("F3: protect XSetEntityUnkillableByUID -> " .. (ok and "called" or "FAILED"))
                end
                log("F3: F4 toggles direct-drive follow (leave his AI alone - unmanaged = parked)")
            end)
        end)
    end)
end)

-- Ghost replay: interpolate the trace like a network interp buffer; positions applied
-- kinematically, velocity + montage derived per segment.
local function ghostTick(a, cmc)
    local tr = drive.trace
    local n = #tr
    drive.ghostT = drive.ghostT + drive.dt
    if drive.ghostT >= tr[n].t then
        drive.ghostT, drive.ghostIdx = 0, 1
        a:K2_SetActorLocation({ X = tr[1].x, Y = tr[1].y, Z = tr[1].z }, false, {}, true)
        log("ghost: loop")
        return
    end
    local i = drive.ghostIdx
    while i < n - 1 and tr[i + 1].t <= drive.ghostT do i = i + 1 end
    drive.ghostIdx = i
    local s1, s2 = tr[i], tr[i + 1]
    local span = s2.t - s1.t
    local al = span > 0 and (drive.ghostT - s1.t) / span or 0
    local x = s1.x + (s2.x - s1.x) * al
    local y = s1.y + (s2.y - s1.y) * al
    local z = s1.z + (s2.z - s1.z) * al
    local dyaw = ((s2.yaw - s1.yaw + 540) % 360) - 180
    local yaw = s1.yaw + dyaw * al
    local speed = s1.speed + (s2.speed - s1.speed) * al
    a:K2_SetActorLocation({ X = x, Y = y, Z = z }, false, {}, true)
    a:K2_SetActorRotation({ Pitch = 0, Yaw = yaw, Roll = 0 }, false)
    local vx = span > 0 and (s2.x - s1.x) / span or 0
    local vy = span > 0 and (s2.y - s1.y) / span or 0
    cmc.Velocity = { X = vx, Y = vy, Z = 0 }
    local anim = getAnim(a)
    if anim then ensureMontage(anim, speed > 30 and speed or 0) end
end

-- Per-frame worker: recorder always runs; then whichever drive mode is active.
local function onFrame()
    if rec.active then
        rec.t = rec.t + drive.dt
        rec.acc = rec.acc + drive.dt
        if rec.acc >= 1 / REC_HZ then
            rec.acc = rec.acc - 1 / REC_HZ
            local pc = UEHelpers.GetPlayerController()
            if pc and pc:IsValid() and pc.Pawn and pc.Pawn:IsValid() then
                local p = pc.Pawn:K2_GetActorLocation()
                local yaw = pc:GetControlRotation().Yaw
                local sp = 0
                pcall(function()
                    local v = pc.Pawn.CharacterMovement.Velocity
                    sp = math.sqrt(v.X * v.X + v.Y * v.Y)
                end)
                rec.samples[#rec.samples + 1] =
                    { t = rec.t, x = p.X, y = p.Y, z = p.Z, yaw = yaw, speed = sp }
            end
        end
    end

    if drive.mode == "off" then return end
    local a = probe.puppet
    if not (a and a:IsValid()) then
        drive.mode = "off"
        log("drive: puppet gone - OFF")
        return
    end
    drive.tick = drive.tick + 1
    local cmc = a.CharacterMovement
    if not (cmc and cmc:IsValid()) then return end

    if drive.mode == "ghost" then
        ghostTick(a, cmc)
        if drive.tick % 180 == 0 then
            log(("ghost: t %.1fs / %.1fs, rate %.2fx")
                :format(drive.ghostT, drive.trace[#drive.trace].t, drive.rate or 0))
        end
        return
    end

    -- ESCORT mode
    local pc = UEHelpers.GetPlayerController()
    if not (pc and pc:IsValid() and pc.Pawn and pc.Pawn:IsValid()) then return end
    local kml = StaticFindObject("/Script/Engine.Default__KismetMathLibrary")
    local pp = pc.Pawn:K2_GetActorLocation()
    local ap = a:K2_GetActorLocation()

    -- station switch clock
    drive.stationTimer = drive.stationTimer + drive.dt
    if not drive.station or drive.stationTimer > drive.stationSpan then pickStation() end

    -- station world point from view yaw; mouse-look swings it, hysteresis absorbs jitter
    local rot = pc:GetControlRotation()
    local fwd = kml:GetForwardVector(rot)
    local rightv = kml:GetRightVector(rot)
    local st = drive.station
    local tx = pp.X + fwd.X * st.f + rightv.X * st.r
    local ty = pp.Y + fwd.Y * st.f + rightv.Y * st.r
    local ex, ey = tx - ap.X, ty - ap.Y
    local dist = math.sqrt(ex * ex + ey * ey)

    -- stuck detector: commanded speed last tick but < 0.5cm actual movement -> kinematic mode
    if drive.lastX and drive.cmdSpeed > 0 and not drive.kinematic then
        local mdx, mdy = ap.X - drive.lastX, ap.Y - drive.lastY
        if (mdx * mdx + mdy * mdy) < 0.25 then
            drive.kinematic = true
            log("drive: CMC integration dead - KINEMATIC fallback on (manual position, velocity for anims)")
        end
    end
    drive.lastX, drive.lastY = ap.X, ap.Y

    local speed = 0
    local wasMoving = drive.moving
    -- hysteresis on station arrival: chase beyond 1.5m error, settle inside 0.75m
    if drive.moving then
        if dist < 75 then drive.moving = false end
    else
        if dist > 150 then drive.moving = true end
    end
    if drive.moving then
        speed = math.min(140 + (dist - 75) * 1.1, 430)
        local vx, vy = ex / dist * speed, ey / dist * speed
        cmc.Velocity = { X = vx, Y = vy, Z = 0 }
        local yaw = math.deg(math.atan(ey, ex))
        a:K2_SetActorRotation({ Pitch = 0, Yaw = yaw, Roll = 0 }, false)
        if drive.kinematic then
            a:K2_SetActorLocation({ X = ap.X + vx * drive.dt, Y = ap.Y + vy * drive.dt, Z = ap.Z }, true, {}, false)
        end
    elseif wasMoving then
        cmc.Velocity = { X = 0, Y = 0, Z = 0 }
        a:K2_SetActorRotation({ Pitch = 0, Yaw = rot.Yaw, Roll = 0 }, false)
    end
    drive.cmdSpeed = speed
    local anim = getAnim(a)
    if anim then ensureMontage(anim, speed) end

    if drive.tick % 180 == 0 then
        local v = cmc.Velocity
        local sp = math.sqrt(v.X * v.X + v.Y * v.Y)
        log(("drive: st=%s err %.1fm, cmd %.0f, vel %.0f cm/s, dt %.1fms, kin=%s, rate %.2fx")
            :format(st.name, dist / 100, speed, sp, drive.dt * 1000,
                tostring(drive.kinematic), drive.rate or 0))
    end
end

local function ensureHook()
    if drive.hooked then return true end
    local ok, err = pcall(function()
        RegisterHook(TICK_HOOK, function(self, geo, dtParam)
            if not drive.alive then
                drive.alive = true
                log("tick hook ALIVE (stat panel ticking)")
            end
            pcall(function()
                local dt = dtParam:get()
                if type(dt) == "number" and dt > 0.001 and dt < 0.2 then drive.dt = dt end
            end)
            local okT, errT = pcall(onFrame)
            if not okT then
                drive.mode = "off"
                rec.active = false
                log("drive ERR (off): " .. tostring(errT))
            end
        end)
    end)
    if not ok then
        log("tick hook FAILED: " .. tostring(err))
        return false
    end
    drive.hooked = true
    log("tick hook registered on HUD stat panel")
    return true
end

-- F2: record own movement into the ghost trace (toggle).
RegisterKeyBind(Key.F2, function()
    ExecuteInGameThread(function()
        if not ensureHook() then return end
        if not rec.active then
            rec.active = true
            rec.samples = {}
            rec.acc, rec.t = 0, 0
            log("F2: RECORDING - move around, F2 again to stop")
        else
            rec.active = false
            if #rec.samples > 1 then
                saveTrace()
                drive.trace = rec.samples
                log("F2: trace armed - F4 cycles to GHOST to replay it")
            else
                log("F2: too few samples, discarded")
            end
        end
    end)
end)

-- F4: cycle drive mode OFF -> ESCORT -> GHOST -> OFF.
RegisterKeyBind(Key.F4, function()
    ExecuteInGameThread(function()
        local nextMode = ({ off = "escort", escort = (drive.trace and "ghost" or "off"),
            ghost = "off" })[drive.mode]
        if nextMode ~= "off" and not (probe.puppet and probe.puppet:IsValid()) then
            log("F4: no live puppet - F3 first")
            return
        end
        if nextMode ~= "off" and not ensureHook() then return end

        -- leaving any active mode: stop the walk loop
        local anim = drive.anim
        if anim and anim:IsValid() and drive.montage and drive.montage:IsValid() then
            pcall(function() anim:Montage_Stop(0.25, drive.montage) end)
        end
        drive.montage = nil

        drive.mode = nextMode
        if nextMode ~= "off" then
            drive.lastX, drive.lastY, drive.cmdSpeed, drive.kinematic = nil, nil, 0, false
            drive.anim, drive.animLogged = nil, false
            drive.slotIdx, drive.moving = 1, false
            drive.station, drive.stationTimer = nil, 0
            armCMC(probe.puppet)
            if nextMode == "ghost" then
                drive.ghostT, drive.ghostIdx = 0, 1
                local s = drive.trace[1]
                probe.puppet:K2_SetActorLocation({ X = s.x, Y = s.y, Z = s.z }, false, {}, true)
            end
        end
        local msgs = {
            off = "OFF - he parks where he stands",
            escort = "ESCORT - 10m stations, hops ahead/behind/left/right every 6-12s",
            ghost = "GHOST - replaying trace (" .. (drive.trace and #drive.trace or 0) .. " samples), loops",
        }
        log("F4: mode = " .. nextMode:upper() .. " | " .. msgs[nextMode])
    end)
end)

-- F9: object dump (own bind now that MolotovFire is retired; harmless double-dump if both loaded)
RegisterKeyBind(Key.F9, function()
    log("F9 object dump starting (game will hitch)")
    local ok, err = pcall(function()
        if type(DumpAllObjects) == "function" then
            DumpAllObjects()
            log("F9 dump complete -> ue4ss/UE4SS_ObjectDump.txt")
        else
            log("F9: DumpAllObjects not exposed in this UE4SS build")
        end
    end)
    if not ok then log("F9 dump ERR: " .. tostring(err)) end
end)
