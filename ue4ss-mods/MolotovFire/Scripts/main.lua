local function log(msg) print("[MolotovFire] " .. msg .. "\n") end

log("loaded")

local UEHelpers = require("UEHelpers")

assert(type(LoopInGameThreadWithDelay) == "function"
    and type(ExecuteInGameThreadWithDelay) == "function"
    and type(CancelDelayedAction) == "function",
    "MolotovFire requires UE4SS game-thread timer APIs")

local equipGeneration = 0
local mp = { cur = {}, bones = {}, freeze = false, step = 0, hooked = false }

local function regAddr(o)
    local ok, a = pcall(function() return o:GetAddress() end)
    return (ok and type(a) == "number") and a or nil
end
local function objAlive(o)
    local ok, r = pcall(function() return o and o:IsValid() end)
    return ok and r == true
end
local function findByAddr(className, addr)
    for _, o in ipairs(FindAllOf(className) or {}) do
        if regAddr(o) == addr then return o end
    end
end

-- Ambient bonfire BP (env set-dressing): self-contained VFX+light, no anomaly-spawner
-- context needed. ClassicFireAnomaly null-derefs when raw-spawned — don't go back.
local FIRE_CLASS_PATH = "/Game/_Stalker_2/VFX/Environment/BonFire/Blueprint/BP_BonFire.BP_BonFire_C"
local BOTTLE_MESH_PATH = "/Game/_Stalker_2/items/consumable/SM_cns_cossacks_vodka_01_c.SM_cns_cossacks_vodka_01_c"
local SPAWN_ARMED = true

-- Real petrol-bomb pool: intense ~25s, rim dies first, heart gone by ~45s.
-- { count, min/max distance (cm), min/max lifetime (s), visual scale }
local RINGS = {
    { count = 1, distMin = 0,  distMax = 0,   lifeMin = 40, lifeMax = 45, scale = 1.4 },  -- heart of the fire
    { count = 4, distMin = 35, distMax = 65,  lifeMin = 32, lifeMax = 40, scale = 1.2 },  -- body
    { count = 5, distMin = 70, distMax = 110, lifeMin = 24, lifeMax = 32, scale = 1.0 },  -- ragged edge
}

-- Track live grenades; a vanished actor's last position = detonation site.
local tracked = {}
local trackedCount = 0
local fires = {}                 -- { actor, dieAt }

local Z_NUDGE = -30   -- BonFire flames emit from log-pile top; sink actor to grass level

local function groundZ(world, x, y, zHint)
    local ksl = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
    if not (ksl and ksl:IsValid()) then return zHint end
    local hit = {}
    local ok, hitSomething = pcall(function()
        -- trace Visibility channel: +150 clears tall grass, -1500 reaches downslope
        return ksl:LineTraceSingle(world,
            { X = x, Y = y, Z = zHint + 150 },
            { X = x, Y = y, Z = zHint - 1500 },
            0, false, {}, 0, hit, true,
            { R = 0, G = 0, B = 0, A = 1 }, { R = 0, G = 0, B = 0, A = 1 }, 0.0)
    end)
    if ok and hitSomething then
        local p = hit.ImpactPoint or hit.Location
        local okZ, zv = pcall(function() return p.Z end)
        if okZ and type(zv) == "number" then return zv end
    end
    return zHint
end

local function spawnGroundFire(x, y, z, hx, hy)
    if not SPAWN_ARMED then
        log(string.format("FIRE (disarmed): would burn at %.0f %.0f %.0f", x, y, z))
        return
    end
    -- splash axis = throw heading (random for F6); pool stretches 1.5x along, 0.8x across
    if not (hx and hy) or (hx == 0 and hy == 0) then
        local a = math.random() * 2 * math.pi
        hx, hy = math.cos(a), math.sin(a)
    end
    local fireClass = StaticFindObject(FIRE_CLASS_PATH)
    if not (fireClass and fireClass:IsValid()) then
        fireClass = LoadAsset(FIRE_CLASS_PATH)
    end
    if not (fireClass and fireClass:IsValid()) then
        log("FIRE: class failed to load")
        return
    end
    local gs = StaticFindObject("/Script/Engine.Default__GameplayStatics")
    local world = UEHelpers.GetWorld()
    if not (gs and gs:IsValid() and world and world:IsValid()) then
        log("FIRE: no GameplayStatics/world")
        return
    end
    -- no extra flash here: the engine explosion (pak ExplosionPrototype) already
    -- provides the fireball+whoosh; a second NS_Barrel_Explo read as a double boom
    local spawned = 0
    for _, ring in ipairs(RINGS) do
        for i = 1, ring.count do
            -- even spacing + jitter reads organic instead of clock-face
            local ang = (i / ring.count) * 2 * math.pi + (math.random() - 0.5)
            local dist = ring.distMin + math.random() * (ring.distMax - ring.distMin)
            local life = ring.lifeMin + math.random() * (ring.lifeMax - ring.lifeMin)
            -- decompose offset into along/across the splash axis, then stretch
            local a = math.cos(ang) * dist * 1.5 + 30   -- +30: splash carries past impact
            local b = math.sin(ang) * dist * 0.8
            local px = x + hx * a - hy * b
            local py = y + hy * a + hx * b
            local pz = groundZ(world, px, py, z) + Z_NUDGE
            local transform = {
                Rotation = { X = 0, Y = 0, Z = 0, W = 1 },
                Translation = { X = px, Y = py, Z = pz },
                Scale3D = { X = ring.scale, Y = ring.scale, Z = ring.scale },
            }
            local ok, err = pcall(function()
                -- UE 5.5: both spawn calls take ESpawnActorScaleMethod (1 = MultiplyWithRoot)
                local actor = gs:BeginDeferredActorSpawnFromClass(world, fireClass, transform, 1, nil, 1)
                if actor and actor:IsValid() then
                    gs:FinishSpawningActor(actor, transform, 1)
                    -- keep flames/light/sound/BurnTriggerCollider; ditch the log-pile mesh
                    pcall(function()
                        local logs = actor.SM_vil_fire_death_01
                        if logs and logs:IsValid() then
                            logs:SetHiddenInGame(true, false)
                            logs:SetCollisionEnabled(0)
                        end
                    end)
                    fires[#fires + 1] = { actor = actor, addr = regAddr(actor), dieAt = os.clock() + life }
                    spawned = spawned + 1
                end
            end)
            if not ok then log("FIRE spawn error: " .. tostring(err)) end
        end
    end
    log(string.format("FIRE: %d patches burning at %.0f %.0f %.0f", spawned, x, y, z))
end

local refreshPoolBurns   -- fwd: assigned beside igniteNearby below

-- Extinguish expired fires; while any burn, keep NPCs standing in the pool alight.
LoopInGameThreadWithDelay(1000, function()
    if #fires == 0 then return false end
    ExecuteInGameThread(function()
        for i = #fires, 1, -1 do
            local f = fires[i]
            if os.clock() >= f.dieAt or not objAlive(f.actor) then
                if objAlive(f.actor) then
                    pcall(function() f.actor:K2_DestroyActor() end)
                end
                table.remove(fires, i)
            end
        end
        if #fires > 0 then pcall(refreshPoolBurns) end
    end)
    return false
end)

-- Impact detonation: glass breaks on contact. Native Grenade:OnHit (dump-verified
-- UFunction, classic hit signature) fires on any blocking contact; Explode() is the
-- on-demand boom. The cfg TimeToExplode (6s) is an engine-side failsafe only.
local function sameObj(a, b)
    local ok, r = pcall(function() return a:GetAddress() == b:GetAddress() end)
    if ok then return r end
    local ok2, r2 = pcall(function() return a:GetFullName() == b:GetFullName() end)
    return ok2 and r2
end

local BURN_RADIUS = 650   -- matches ExplosionMolotov ConcussionRadius
local POOL_BURN_RADIUS = 210   -- standing in a patch's flames (visuals run 1.0-1.4x bonfire)

-- Engine's TIMED detonation applies cfg ConcussionEffects; manual Explode() bypasses
-- that wrapper (NPCs flinched but never ignited) — so burn them via the cheat shard.
-- Shared by the splash and the pool refresh: apply MolotovBurning to every NPC within
-- radius of ANY point in `points` ({ {x,y,z,r}, ... }). tag=nil silences the report.
local function burnNPCsNear(points, tag)
    local rk
    for _, o in ipairs(FindAllOf("CustomConsoleManagerRK") or {}) do
        if o:IsValid() and not o:GetFullName():find("Default__") then rk = o break end
    end
    local cm = StaticFindObject("/Script/Stalker2.Default__CppMediator")
    if not (rk and cm and cm:IsValid()) then
        if tag then log(tag .. ": no RK shard/CppMediator") end
        return
    end
    local pawn
    pcall(function()
        local pc = UEHelpers.GetPlayerController()
        if pc and pc:IsValid() then pawn = pc.Pawn end
    end)
    local applied = 0
    for _, npc in ipairs(FindAllOf("Obj") or {}) do   -- Obj = native character base (ZoneLink-proven)
        pcall(function()
            if not npc:IsValid() or npc:GetFullName():find("Default__") then return end
            if pawn and pawn:IsValid() and npc:GetAddress() == pawn:GetAddress() then return end
            local loc = npc:K2_GetActorLocation()
            local near = false
            for _, p in ipairs(points) do
                local dx, dy, dz = loc.X - p.x, loc.Y - p.y, loc.Z - p.z
                if dx * dx + dy * dy + dz * dz <= p.r * p.r then near = true break end
            end
            if not near then return end
            local uid = cm:GetGUID(npc)
            if type(uid) == "number" and uid ~= 0 then
                rk:XApplyEffectOnNPCByUID("MolotovBurning", uid)
                applied = applied + 1
            end
        end)
    end
    if tag then log(string.format("%s: MolotovBurning applied to %d NPC(s)", tag, applied)) end
end

local function igniteNearby(x, y, z)
    burnNPCsNear({ { x = x, y = y, z = z, r = BURN_RADIUS } }, "ignite")
end

-- The pool keeps burning what stands in it. Without this, env-fire patches only ever
-- burn the PLAYER (vanilla BurnTriggerCollider behavior) — mutants walked through the
-- fire unfazed because the initial 15s burn can't outrun their 5%/s regen. KeepNew on
-- the effect means each 1s pass just refreshes duration while they linger.
local poolLogAt = 0
refreshPoolBurns = function()
    local pts = {}
    for _, f in ipairs(fires) do
        if objAlive(f.actor) then
            pcall(function()
                local l = f.actor:K2_GetActorLocation()
                pts[#pts + 1] = { x = l.X, y = l.Y, z = l.Z, r = POOL_BURN_RADIUS }
            end)
        end
    end
    if #pts == 0 then return end
    local now = os.clock()
    local tag = now >= poolLogAt and "pool" or nil
    if tag then poolLogAt = now + 5 end   -- at most one report per 5s
    burnNPCsNear(pts, tag)
end

-- (unused) kept for the seen-sets only

local function detonate(t, x, y, z, how)
    if t.detonated then return end
    t.detonated = true
    if t.alive then
        t.alive = false
        trackedCount = trackedCount - 1
    end
    local g = objAlive(t.actor) and t.actor or nil
    pcall(function()
        if g and g:IsValid() then g:Explode() end
    end)
    log(string.format("BOOM (%s) at %.0f %.0f %.0f", how, x, y, z))
    local okF, errF = pcall(spawnGroundFire, x, y, z, t.hx, t.hy)
    if not okF then log("FIRE handler error: " .. tostring(errF)) end
    local okI, errI = pcall(igniteNearby, x, y, z)
    if not okI then log("ignite error: " .. tostring(errI)) end
end

local okHit, errHit = pcall(function()
    -- hook body = pointer match + flag ONLY: unwrapping the FHitResult param /
    -- calling Explode() inside the physics hit dispatch AV'd in UE4SS (0x38);
    -- the 100ms tracker loop detonates from its proven-safe context instead
    RegisterHook("/Script/Stalker2.Grenade:OnHit", function(selfParam)
        pcall(function()
            if trackedCount == 0 then return end
            local g = selfParam:get()
            local gaddr = regAddr(g)
            if not gaddr then return end
            for _, t in ipairs(tracked) do
                if t.alive and t.armed and not t.detonated and not t.hitPending
                        and t.addr == gaddr then
                    t.hitPending = true
                    return
                end
            end
        end)
    end)
end)
log(okHit and "impact hook armed on Grenade:OnHit"
    or ("impact hook FAILED (fuse fallback only): " .. tostring(errHit)))

-- Flight look: in-hand bend clamp (0.75) lets the cap flame comet away from a
-- tumbling bottle and the unlit cloth goes invisible in the dark — tame the bend +
-- overdrive the burn film on THIS grenade's MIDs only. The actor is constructed AT
-- the throw and short lobs land in ~300ms (log-proven: BOOM before bottleize), so
-- apply on a fast retry ladder from frame 1 instead of bottleize's 300ms delay; the
-- MolotovRag/RagFlame name gate holds off until the cfg materials are actually in.
local FLIGHT_BENDCLAMP = 0.35
local FLIGHT_BURNGLOW = 2.2
local FLIGHT_DROOP = 6.0  -- pin offset = (dir - tangent) * vcR * this; 1.0 was ~2cm (sub-visible)
-- static twin has no bones: pin the rag's droop direction instead — Skif's toss
-- is consistent, so a fixed up+slightly-right-of-throw trail reads as drag
local FLIGHT_PIN_UP, FLIGHT_PIN_RIGHT, FLIGHT_PIN_BACK = 0.75, 0.35, 0.25

local function flightPinDir()
    local yaw = 0
    pcall(function()
        yaw = UEHelpers.GetPlayerController():GetControlRotation().Yaw
    end)
    local r = math.rad(yaw)
    local fx, fy = math.cos(r), math.sin(r)
    local dx = -fy * FLIGHT_PIN_RIGHT - fx * FLIGHT_PIN_BACK
    local dy = fx * FLIGHT_PIN_RIGHT - fy * FLIGHT_PIN_BACK
    local dz = FLIGHT_PIN_UP
    local len = math.sqrt(dx * dx + dy * dy + dz * dz)
    return { R = dx / len, G = dy / len, B = dz / len, A = 0.0 }
end

local function tuneFlightLook(grenade, attempt)
    ExecuteInGameThread(function()
        local done = false
        pcall(function()
            if not objAlive(grenade) then done = true return end
            local sid
            pcall(function()
                local v = grenade.SID
                local s = tostring(v and v.ToString and v:ToString() or v)
                if s ~= "" and s ~= "nil" then sid = s end
            end)
            if sid and not sid:find("Molotov") then done = true return end   -- RGD5/F1
            local smcClass = StaticFindObject("/Script/Engine.StaticMeshComponent")
            local comp = smcClass and smcClass:IsValid()
                and grenade:GetComponentByClass(smcClass) or nil
            if not (comp and comp:IsValid()) then return end   -- comp not built yet, retry
            local pin = flightPinDir()
            local tuned = 0
            for i = 0, comp:GetNumMaterials() - 1 do
                local m = comp:GetMaterial(i)
                local fn = (m and m:IsValid()) and m:GetFullName() or ""
                if fn:find("MolotovRag", 1, true) or fn:find("RagFlame", 1, true)
                        or fn:find("SheathFlame", 1, true) then
                    local mid = comp:CreateDynamicMaterialInstance(i, m, FName("None"))
                    if mid and mid:IsValid() then
                        mid:SetScalarParameterValue(FName("BendClamp"), FLIGHT_BENDCLAMP)
                        mid:SetScalarParameterValue(FName("BurnGlow"), FLIGHT_BURNGLOW)
                        if fn:find("MolotovRag", 1, true) then
                            -- cloth only: the tip card's droop is still the old
                            -- world-down chain and would dive opposite the pin
                            mid:SetScalarParameterValue(FName("DroopStrength"), FLIGHT_DROOP)
                            pcall(function()
                                mid:SetVectorParameterValue(FName("DroopDir"), pin)
                            end)
                        else
                            mid:SetScalarParameterValue(FName("DroopStrength"), 0.0)
                        end
                        tuned = tuned + 1
                    end
                end
            end
            if tuned > 0 then
                done = true
                log(string.format("flightlook: %d slot(s) tuned (attempt %d)", tuned, attempt))
            end
            -- rag materials not on the comp yet (cfg mesh still initializing) -> retry
        end)
        if not done and attempt < 12 then
            ExecuteInGameThreadWithDelay(50, function() tuneFlightLook(grenade, attempt + 1) end)
        end
    end)
end

local douseRagFire   -- fwd decl: fp lives below; assigned beside ragFire

local grenSeen = {}
LoopInGameThreadWithDelay(60, function()
    ExecuteInGameThread(function()
        pcall(function()
            for _, grenade in ipairs(FindAllOf("BP_Grenade_C") or {}) do
                if grenade:IsValid() and not grenade:GetFullName():find("Default__") then
                    local gaddr = regAddr(grenade)
                    if gaddr and not grenSeen[gaddr] then
                        grenSeen[gaddr] = true
                        tracked[#tracked + 1] = { addr = gaddr, actor = grenade, x = 0, y = 0, z = 0, alive = true, seen = 0 }
                        trackedCount = trackedCount + 1
                        log("grenade spawned (equipped)")
                        if douseRagFire then douseRagFire("thrown") end
                        ExecuteInGameThreadWithDelay(16, function() tuneFlightLook(grenade, 1) end)
                        ExecuteInGameThreadWithDelay(300, function()
                            ExecuteInGameThread(function()
                                local ok, err = pcall(function()
                                    if not objAlive(grenade) then log("bottleize: actor gone") return end
                                    local g = grenade
                                    local sid = "unreadable"
                                    pcall(function()
                                        local v = g.SID
                                        local s = tostring(v and v.ToString and v:ToString() or v)
                                        if s ~= "" and s ~= "nil" then sid = s end
                                    end)
                                    log("bottleize: SID = " .. sid)
                                    if not (sid:find("Molotov") or sid == "unreadable") then
                                        log("bottleize: not a molotov, skipping")
                                        for _, t in ipairs(tracked) do
                                            if t.alive and t.addr == gaddr then
                                                t.alive = false
                                                trackedCount = trackedCount - 1
                                                log("untracked non-molotov (no fire for RGD5/F1)")
                                            end
                                        end
                                        return
                                    end
                                    log("bottleize: cfg mesh in use")
                                end)
                                if not ok then log("bottleize ERR: " .. tostring(err)) end
                            end)
                        end)
                    end
                end
            end
        end)
    end)
    return false
end)

LoopInGameThreadWithDelay(100, function()
    if trackedCount == 0 then return false end
    ExecuteInGameThread(function()
        for _, t in ipairs(tracked) do
            if t.alive then
                local ok = pcall(function()
                    local g = objAlive(t.actor) and t.actor or nil
                    -- deferred impact: flagged by the OnHit hook, executed here
                    if t.hitPending and not t.detonated then
                        t.hitPending = nil
                        local sid, px, py, pz = "", t.x, t.y, t.z
                        if g then
                            pcall(function()
                                local v = g.SID
                                sid = tostring(v and v.ToString and v:ToString() or v)
                            end)
                            pcall(function()   -- resting spot = true ground zero
                                local loc = g:K2_GetActorLocation()
                                if not (loc.X == 0 and loc.Y == 0 and loc.Z == 0) then
                                    px, py, pz = loc.X, loc.Y, loc.Z
                                end
                            end)
                        end
                        if sid:find("Molotov") then
                            detonate(t, px, py, pz, "impact")
                            return
                        end
                        -- non-molotov slipped in pre-bottleize: engine timer keeps it
                    end
                    -- fallback fuse: soft landings (water/bushes) may never fire OnHit
                    if t.armed and os.clock() >= t.boomAt then
                        detonate(t, t.x, t.y, t.z, "fuse fallback")
                        return
                    end
                    if g then
                        local loc = g:K2_GetActorLocation()
                        if (loc.X == 0 and loc.Y == 0 and loc.Z == 0) then
                            local root = g.RootComponent
                            if root and root:IsValid() then
                                loc = root:K2_GetComponentLocation()
                            end
                        end
                        if not (loc.X == 0 and loc.Y == 0 and loc.Z == 0) then
                            if t.seen > 0 then
                                local dx, dy, dz = loc.X - t.x, loc.Y - t.y, loc.Z - t.z
                                local h2 = dx * dx + dy * dy
                                if h2 > 60 * 60 then
                                    local h = math.sqrt(h2)
                                    t.hx, t.hy = dx / h, dy / h   -- latest flight heading
                                end
                                -- >120cm between 100ms reads = 12 m/s: throws hit ~15-25, sprint ~7
                                if not t.armed and h2 + dz * dz > 120 * 120 then
                                    t.armed = true
                                    -- fallback only; a 45-deg lob at 20 m/s flies ~3s
                                    t.boomAt = os.clock() + 3.5
                                    log("thrown - impact watch armed")
                                end
                            end
                            t.x, t.y, t.z = loc.X, loc.Y, loc.Z
                            t.seen = (t.seen or 0) + 1
                            if t.seen % 10 == 1 then
                                log(string.format("tracking %.0f %.0f %.0f", t.x, t.y, t.z))
                            end
                        end
                    else
                        t.alive = false
                        trackedCount = trackedCount - 1
                        if t.armed and not t.detonated then
                            -- died mid-fuse = engine detonated it; last position is ground zero
                            t.detonated = true
                            log(string.format("BOOM (actor died) at %.0f %.0f %.0f", t.x, t.y, t.z))
                            local okF, errF = pcall(spawnGroundFire, t.x, t.y, t.z, t.hx, t.hy)
                            if not okF then log("FIRE handler error: " .. tostring(errF)) end
                        else
                            log(string.format("grenade despawned unarmed (reads=%d)", t.seen or 0))
                        end
                    end
                end)
                if not ok and t.alive then
                    t.alive = false
                    trackedCount = trackedCount - 1
                    log("tracker error; entry dropped")
                end
            end
        end
    end)
    return false
end)

-- FP idle-hold: the raised grenade is a WeaponInHandsMesh skeletal comp on Skif —
-- no grenade actor exists until the throw. Its AnimBP constructing = hands coming up.
local FP_ANIM_PATH = "/Game/_STALKER2/Animations/Weapons/grenades/RGD5/AnimBP_Rgd5_fp.AnimBP_Rgd5_fp_C"
local fp = {}   -- bottle comp + hands mesh + anim full-name while swapped

-- TUNE MODE (Home toggles; player movement locked while on):
--   W/S = screen up/down, A/D = left/right, PgUp/PgDn = toward/away camera
--   arrows = pitch/yaw, ,/. = roll, -/= = scale, V = hide bottle (pivot marker stays)
--   End = fine steps. Deltas ride the auto grenade-matched base pose and move the
--   bottle's MID-BODY: the mesh pivot sits at the bottle BASE, so each apply solves
--   the location that puts the bounds CENTER (not the pivot) on base+delta.
-- BAKED 2026-10-19 (user-approved in-fist pose: neck out between the fingers):
-- deltas ride the baked locked base below — together they form one constant
-- hand-relative transform, so the bottle is rigid on jnt_r_hand (no fidget swim).
local bottleOff = { s = 0.4, x = 0.4, y = -9.8, z = -9.1, rx = -90, ry = 0, rz = -60 }
local tuneMode, fineStep = false, false
local showPivotMarker   -- fwd-declared; defined with the tuner keys below
-- baked fidget-pose base (K in tune mode re-locks/unlocks live tracking)
local lockedBase = {
    loc = { x = -12.0, y = -0.9, z = -18.1 },
    rot = { p = 28.1, yaw = 29.6, r = -114.3 },
}
local consumeNudges     -- fwd-declared; tuner intents run inside the tick hook
-- keybind handlers push plain data only — UObject calls from rapid
-- ExecuteInGameThread keypresses raced the tick hook inside UE4SS (AV at 0x36)
local nudgeQueue = {}
local function queueNudge(n)
    if fp.bottle then nudgeQueue[#nudgeQueue + 1] = n end
end

local function socketNames(mesh)
    local names = {}
    local function unwrap(raw)
        local v = raw
        pcall(function() if raw.get then v = raw:get() end end)   -- TArray elems are RemoteUnrealParam
        return tostring(v and v.ToString and v:ToString() or v)
    end
    pcall(function()
        local arr = mesh:GetAllSocketNames()
        for i = 1, #arr do names[#names + 1] = unwrap(arr[i]) end
    end)
    if #names == 0 then
        pcall(function()
            local n = mesh:GetNumBones()
            for i = 0, math.min(n - 1, 15) do names[#names + 1] = unwrap(mesh:GetBoneName(i)) end
        end)
    end
    return names
end

-- the FP anim moves the grenade's BONES into the hand; comp root stays put
local function pickGrenadeBone(mesh)
    local names = socketNames(mesh)
    log("FP sockets/bones: " .. (#names > 0 and table.concat(names, ", ") or "(none found)"))
    for _, nm in ipairs(names) do
        local l = nm:lower()
        if l:find("gre") or l:find("body") or l:find("item") or l:find("wpn") then return nm end
    end
    return names[#names]   -- leaf bone of a tiny rig = the item itself; nil -> root
end

-- right-hand bone on the VISIBLE body rig — the hidden grenade rig's pose goes
-- idle/frozen during locomotion, so its bones bob with the legs, not the hand
local function pickHandBone(mesh, fallback)
    local hands = {}
    for _, nm in ipairs(socketNames(mesh)) do
        if nm:lower():find("hand") then hands[#hands + 1] = nm end
    end
    log("FP: body hand bones: " .. (#hands > 0 and table.concat(hands, ", ") or "(none)"))
    for _, pat in ipairs({ "^jnt_r_hand$", "r_hand", "hand_r", "righthand" }) do
        for _, nm in ipairs(hands) do
            if nm:lower():find(pat) then return nm end
        end
    end
    if fallback and fallback ~= "" and fallback ~= "None" then return fallback end
    return hands[1]
end

-- The pose is authored relative to the WRIST (jnt_r_hand) but the bottle must RIDE
-- a fist bone: gait rotates the wrist, and rotation x the ~30cm wrist->fist lever
-- bobbed the bottle in step cadence while the (steady) fist barely moves.
local GRIP_BONES = { "jnt_r_hand_middle_01", "jnt_r_hand_middle_meta" }

-- Resolve the stashed FP objects. Called from the game thread only, right before
-- use — never stash the results.
local function fpBottle() return objAlive(fp.bottle) and fp.bottle or nil end
local function fpMesh() return objAlive(fp.mesh) and fp.mesh or nil end
local function fpAnchor() return objAlive(fp.anchor) and fp.anchor or nil end
local function fpMarker() return objAlive(fp.marker) and fp.marker or nil end

local function attachWrist()   -- snap back to the authoring frame (zero relative)
    local b, a = fpBottle(), fpAnchor()
    if b and a then b:K2_AttachToComponent(a, FName(fp.boneName or "None"), 2, 2, 0, false) end
end

local function regrip()   -- KeepWorld re-attach: same world pose, short fist lever
    pcall(function()
        local bottle, anchor = fpBottle(), fpAnchor()
        if not (bottle and anchor) then return end
        local grip
        for _, b in ipairs(GRIP_BONES) do
            if anchor:DoesSocketExist(FName(b)) then grip = b break end
        end
        if not grip then return end
        bottle:K2_AttachToComponent(anchor, FName(grip), 1, 1, 1, false)
        if not fp.gripLogged then
            fp.gripLogged = true
            local rl, rr = bottle.RelativeLocation, bottle.RelativeRotation
            log(string.format("FP: riding %s rel %.1f %.1f %.1f rot %.1f %.1f %.1f",
                grip, rl.X, rl.Y, rl.Z, rr.Pitch, rr.Yaw, rr.Roll))
        end
    end)
end

local function applyBottleTune()
    pcall(function()
        local bottle = fpBottle()
        if bottle then
            if fpAnchor() then attachWrist() end
            local bl = fp.baseLoc or { x = 0, y = 0, z = 0 }
            local br = fp.baseRot or { p = 0, yaw = 0, r = 0 }
            local rot = { Pitch = br.p + bottleOff.ry, Yaw = br.yaw + bottleOff.rz, Roll = br.r + bottleOff.rx }
            -- grip target in bone space; the bottle's bounds CENTER goes here, which
            -- cancels out the mesh pivot sitting at the bottle's base
            local tx, ty, tz = bl.x + bottleOff.x, bl.y + bottleOff.y, bl.z + bottleOff.z
            local c = fp.midLocal or { x = 0, y = 0, z = 17 }
            local kml = StaticFindObject("/Script/Engine.Default__KismetMathLibrary")
            local fv = kml:GetForwardVector(rot)
            local rv = kml:GetRightVector(rot)
            local uv = kml:GetUpVector(rot)
            local ox = (fv.X * c.x + rv.X * c.y + uv.X * c.z) * bottleOff.s
            local oy = (fv.Y * c.x + rv.Y * c.y + uv.Y * c.z) * bottleOff.s
            local oz = (fv.Z * c.x + rv.Z * c.y + uv.Z * c.z) * bottleOff.s
            bottle:SetRelativeScale3D({ X = bottleOff.s, Y = bottleOff.s, Z = bottleOff.s })
            bottle:K2_SetRelativeLocation({ X = tx - ox, Y = ty - oy, Z = tz - oz }, false, {}, false)
            bottle:K2_SetRelativeRotation(rot, false, {}, false)
            local mk = fpMarker()
            if mk then   -- marker = the grip/mid point
                mk:K2_SetRelativeLocation({ X = tx, Y = ty, Z = tz }, false, {}, false)
            end
            regrip()
        end
    end)
end

local function logBottleOff(prefix)
    log(string.format("%s scale %.2f offset %g %g %g rot %g %g %g%s",
        prefix, bottleOff.s, bottleOff.x, bottleOff.y, bottleOff.z,
        bottleOff.rx, bottleOff.ry, bottleOff.rz, fineStep and " (fine)" or ""))
end

-- snap bottle to the in-hand grenade body bone, then store the resulting relative
-- transform (on jnt_r_hand) as the base pose — tuner offsets are deltas from it
local function sampleGrenadeBase(tag, forceLive)
    if lockedBase and not forceLive then   -- captured fidget pose wins over live sampling
        fp.baseLoc = { x = lockedBase.loc.x, y = lockedBase.loc.y, z = lockedBase.loc.z }
        fp.baseRot = { p = lockedBase.rot.p, yaw = lockedBase.rot.yaw, r = lockedBase.rot.r }
        if tag then log("FP: using LOCKED fidget base (" .. tag .. ")") end
        applyBottleTune()
        return
    end
    local ok, err = pcall(function()
        local bottle, mesh = fpBottle(), fpMesh()
        if not (bottle and mesh) then return end
        attachWrist()   -- readback below must be wrist-relative (authoring frame)
        local gl = mesh:GetSocketLocation(FName("jnt_wpn_rgd5"))
        local gr = mesh:GetSocketRotation(FName("jnt_wpn_rgd5"))
        bottle:K2_SetWorldLocationAndRotation(
            { X = gl.X, Y = gl.Y, Z = gl.Z },
            { Pitch = gr.Pitch, Yaw = gr.Yaw, Roll = gr.Roll }, false, {}, false)
        local rl, rr = bottle.RelativeLocation, bottle.RelativeRotation
        fp.baseLoc = { x = rl.X, y = rl.Y, z = rl.Z }
        fp.baseRot = { p = rr.Pitch, yaw = rr.Yaw, r = rr.Roll }
        if tag then
            log(string.format("FP: grenade-match (%s) base loc %.1f %.1f %.1f rot %.0f %.0f %.0f",
                tag, rl.X, rl.Y, rl.Z, rr.Roll, rr.Pitch, rr.Yaw))
        end
    end)
    if not ok and tag then log("grenade-match ERR: " .. tostring(err)) end
    applyBottleTune()
end

-- Live grenade-match v3: re-base per frame from a native RegisterHook (game thread,
-- registered once — the old LoopAsync(16)+ExecuteInGameThread approach queued fresh
-- Lua registry refs 60x/sec and raced UE4SS's callback GC = access violation).
-- Source: HUD stat-panel widget Tick (ZoneLink-proven, fires natively every frame);
-- the grenade AnimBP owns only AnimGraph (dump-verified) — nothing to hook there.
local function handGrenadeDistances()
    local mesh, anchor = fpMesh(), fpAnchor()
    if not (mesh and anchor) then return nil, nil end
    local g = mesh:GetSocketLocation(FName("jnt_wpn_rgd5"))
    local function dist(bone)
        local h = anchor:GetSocketLocation(FName(bone))
        local dx, dy, dz = g.X - h.X, g.Y - h.Y, g.Z - h.Z
        return math.sqrt(dx * dx + dy * dy + dz * dz)
    end
    return dist(fp.boneName or "jnt_r_hand"), dist("jnt_l_hand")
end

-- Weld the bottle to the FP rig bone itself: the rig is authored for the warped FP
-- view, so body wrist/fist anchors always move out of proportion with the rendered
-- hand. Author the approved pose (wrist frame), then KeepWorld re-attach to the
-- bone — the engine turns it into a constant bone-local offset (rigid, no swim).
local function rigWeld()
    pcall(function()
        local bottle, mesh = fpBottle(), fpMesh()
        if not (bottle and mesh) then return end
        sampleGrenadeBase(nil)
        bottle:K2_AttachToComponent(mesh, FName("jnt_wpn_rgd5"), 1, 1, 1, false)
        fp.welded = true
        if not fp.weldLogged then
            fp.weldLogged = true
            local rl, rr = bottle.RelativeLocation, bottle.RelativeRotation
            log(string.format("FP: welded to jnt_wpn_rgd5 rel %.1f %.1f %.1f rot %.1f %.1f %.1f",
                rl.X, rl.Y, rl.Z, rr.Pitch, rr.Yaw, rr.Roll))
        end
    end)
end

local function trackTick()
    if not (fp.bottle and fp.mesh and fp.anchor
            and fp.anchor ~= fp.mesh
            and objAlive(fp.bottle) and objAlive(fp.mesh) and objAlive(fp.anchor)) then return end
    local okD, dR, dL = pcall(handGrenadeDistances)
    if okD and dR then
        local d = math.min(dR, dL)
        fp.tickN = (fp.tickN or 0) + 1
        if fp.tickN % 240 == 0 then   -- instrumentation (~every 4s)
            log(string.format("FP: d=%.0f%s", d, fp.welded and " (welded)" or ""))
        end
        if lockedBase then
            if fp.welded then
                -- locomotion desyncs the hidden rig (bones ride the legs); windup also
                -- grows d but the player is near-still — speed disambiguates
                if d > 35 then
                    local speed = 0
                    pcall(function()
                        local v = UEHelpers.GetPlayerController().Pawn.CharacterMovement.Velocity
                        speed = math.sqrt(v.X * v.X + v.Y * v.Y)
                    end)
                    if speed > 120 then
                        fp.welded = nil
                        log(string.format("FP: rig desync (d=%.0f v=%.0f) - fist hold", d, speed))
                        sampleGrenadeBase(nil)
                    end
                end
            elseif d <= 30 then
                rigWeld()
            end
        elseif d <= 35 then   -- unlocked live mode: hold last base past the desync gate
            if dL + 5 < dR then
                if not fp.leftLogged then
                    fp.leftLogged = true
                    log(string.format("FP: grenade bone nearer LEFT hand (L %.0f vs R %.0f) - fidget hand-swap?", dL, dR))
                end
            elseif dR <= dL then
                fp.leftLogged = nil
            end
            sampleGrenadeBase(nil)   -- quiet re-base; tuner deltas ride on top
        end
    end
    if consumeNudges then consumeNudges() end
end

local HUD_TICK_HOOK = "/Game/GameLite/FPS_Game/UIRemaster/HUD/StatPanel/W_UpdatedStatPanel.W_UpdatedStatPanel_C:Tick"
local trackHooked, trackHookLogged = false, false
local function hookGrenadeTick()
    -- MUST be called from main-state context (notify/keybind callback): registering
    -- from the async state stores a dead ref -> "Ref was not function", no tracking
    if trackHooked then return end
    local ok, err = pcall(function()
        RegisterHook(HUD_TICK_HOOK, function()
            if fp.bottle then pcall(trackTick) end
        end)
    end)
    trackHooked = ok
    if trackHooked then
        log("FP: live grenade-path tracking via HUD stat-panel Tick")
    elseif not trackHookLogged then
        trackHookLogged = true
        log("FP: HUD tick hook failed (" .. tostring(err) .. ") - static base only")
    end
end

local function fpRestore()
    equipGeneration = equipGeneration + 1
    mp.cur = {}
    pcall(function()
        if objAlive(fp.mesh) then
            fp.mesh:SetVisibility(true, false)
            if fp.prevTick ~= nil then fp.mesh.VisibilityBasedAnimTickOption = fp.prevTick end
        end
    end)
    pcall(function() if objAlive(fp.bottle) then fp.bottle:K2_DestroyComponent(fp.bottle) end end)
    pcall(function() if objAlive(fp.marker) then fp.marker:K2_DestroyComponent(fp.marker) end end)
    pcall(function() if objAlive(fp.handDot) then fp.handDot:K2_DestroyComponent(fp.handDot) end end)
    pcall(function() if objAlive(fp.rag) then fp.rag:K2_DestroyComponent(fp.rag) end end)
    for _, c in ipairs(fp.ragLower or {}) do
        pcall(function() if objAlive(c) then c:K2_DestroyComponent(c) end end)
    end
    fp.ragLower = nil
    fp.bottle, fp.mesh, fp.animName, fp.prevTick = nil, nil, nil, nil
    fp.anchor, fp.boneName, fp.baseLoc, fp.baseRot = nil, nil, nil, nil
    fp.marker, fp.handDot, fp.hiddenForPivot, fp.leftLogged, fp.midLocal = nil, nil, nil, nil, nil
    fp.rag = nil
    fp.gripLogged, fp.welded, fp.weldLogged, fp.tickN, fp.flameAnim = nil, nil, nil, nil, nil
end

local function mainHandSID()
    local sid = "unreadable"
    pcall(function()
        local cm = StaticFindObject("/Script/Stalker2.Default__CppMediator")
        if cm and cm:IsValid() then
            local data = cm:GetPlayerItemInHandsData()
            local v = data.MainHandItemPrototypeID
            local s = tostring(v and v.ToString and v:ToString() or v)
            if s ~= "" and s ~= "nil" then sid = s end
        end
    end)
    return sid
end

local function currentRagMesh(anim)
    if mainHandSID() ~= "GrenadeMolotov" or not objAlive(anim) then return nil end
    local mesh
    pcall(function() mesh = anim:GetOwningComponent() end)
    if not objAlive(mesh) then
        pcall(function() mesh = anim:GetOuter() end)
    end
    if not objAlive(mesh) then return nil end
    local current = mesh.AnimScriptInstance
    if not objAlive(current) or not sameObj(current, anim) then return nil end
    local assetName = ""
    pcall(function() assetName = mesh:GetSkeletalMeshAsset():GetFullName() end)
    if assetName ~= "" and not assetName:find("SK_MolotovBottle", 1, true) then return nil end
    return mesh
end

local fpSwap   -- fwd-decl: equip swap retries while rig socket names are unreadable
fpSwap = function(anim, attempt)
    -- let the game finish wiring mesh+anim before restyling it
    ExecuteInGameThreadWithDelay(attempt == 1 and 150 or 400, function()
        ExecuteInGameThread(function()
            local ok, err = pcall(function()
                if not (anim and anim:IsValid()) then return end
                local sid = mainHandSID()
                log("hands up: main hand = " .. sid)
                if not (sid:find("Molotov") or sid == "unreadable") then return end
                local mesh
                pcall(function() mesh = anim:GetOwningComponent() end)
                if not (mesh and mesh:IsValid()) then
                    -- dump: the AnimBP instance's outer IS the WeaponInHandsMesh comp
                    pcall(function() mesh = anim:GetOuter() end)
                end
                if not (mesh and mesh:IsValid()) then log("FP: no hands mesh") return end
                fpRestore()
                local bottle = StaticFindObject(BOTTLE_MESH_PATH) or LoadAsset(BOTTLE_MESH_PATH)
                local smcClass = StaticFindObject("/Script/Engine.StaticMeshComponent")
                local owner = mesh:GetOwner()
                if not (bottle and bottle:IsValid() and smcClass and smcClass:IsValid()
                        and owner and owner:IsValid()) then
                    log("FP: prereqs missing")
                    return
                end
                local idT = { Rotation = { X = 0, Y = 0, Z = 0, W = 1 },
                              Translation = { X = 0, Y = 0, Z = 0 },
                              Scale3D = { X = 1, Y = 1, Z = 1 } }
                local comp = owner:AddComponentByClass(smcClass, true, idT, false)
                if not (comp and comp:IsValid()) then log("FP: AddComponentByClass failed") return end
                comp:SetStaticMesh(bottle)
                comp:SetCollisionEnabled(0)
                pcall(function()   -- mesh-local bounds center; pivot is at the bottle BASE
                    local mn, mx = {}, {}
                    comp:GetLocalBounds(mn, mx)
                    if mn.Z and mx.Z then
                        fp.midLocal = { x = (mn.X + mx.X) / 2, y = (mn.Y + mx.Y) / 2, z = (mn.Z + mx.Z) / 2 }
                        log(string.format("FP: bottle mid-local %.1f %.1f %.1f", fp.midLocal.x, fp.midLocal.y, fp.midLocal.z))
                    end
                end)
                -- UE5.5 FP pass warps arms toward camera; unflagged comps render ~2x too far out
                pcall(function() comp:SetFirstPersonPrimitiveType(1) end)   -- 1 = FirstPerson
                -- anchor to the body rig the player SEES; the hidden grenade rig desyncs in locomotion
                local parent, parentSock
                pcall(function() parent = mesh:GetAttachParent() end)
                pcall(function()
                    local s = mesh:GetAttachSocketName()
                    parentSock = tostring(s and s.ToString and s:ToString() or s)
                end)
                local target, bone = nil, nil
                if parent and parent:IsValid() then
                    log("FP: grenade mesh rides " .. parent:GetFullName() .. " @ " .. tostring(parentSock))
                    bone = pickHandBone(parent, parentSock)
                    if bone then target = parent end
                end
                if not target then   -- fallback: old grenade-bone attach
                    target, bone = mesh, pickGrenadeBone(mesh)
                end
                if not bone or bone == "None" then
                    -- unreadable socket names = attach lands on a rigid comp root (the
                    -- levitating-bottle failure); give the rig time to wire and retry
                    pcall(function() comp:K2_DestroyComponent(comp) end)
                    if attempt < 4 then
                        log(string.format("FP: bones unreadable (attempt %d) - retrying", attempt))
                        fpSwap(anim, attempt + 1)
                    else
                        log("FP: bones never resolved - swap skipped (grenade stays visible)")
                    end
                    return
                end
                -- hidden skel meshes stop ticking; keep grenade rig posed so we can sample it
                pcall(function()
                    fp.prevTick = mesh.VisibilityBasedAnimTickOption
                    mesh.VisibilityBasedAnimTickOption = 0   -- AlwaysTickPoseAndRefreshBones
                end)
                comp:K2_AttachToComponent(target, FName(bone or "None"), 2, 2, 0, false)
                mesh:SetVisibility(false, false)   -- hide grenade; child bottle stays visible
                fp.bottle, fp.mesh, fp.animName = comp, mesh, anim:GetFullName()
                fp.anchor, fp.boneName = target, bone
                sampleGrenadeBase("equip")
                if tuneMode and showPivotMarker then showPivotMarker(true) end
                -- flaming rag POC: dump-verified lamp/candle flame parked at the neck;
                -- child of the bottle comp so it inherits scale and rides the tune
                local ragOk, ragErr = pcall(function()
                    local ncClass = StaticFindObject("/Script/Niagara.NiagaraComponent")
                    if not (ncClass and ncClass:IsValid()) then log("FP: rag - NiagaraComponent class missing") return end
                    local ns, nsPath
                    for _, p in ipairs({
                        "/Game/_Stalker_2/VFX/Environment/Fire/Niagara/NS_Fire_Kerosene_2.NS_Fire_Kerosene_2",
                        "/Game/_Stalker_2/VFX/Environment/Fire/Niagara/NS_Fire_Candle_2.NS_Fire_Candle_2",
                        "/Game/_Stalker_2/VFX/Environment/Fire/Niagara/NS_Fire_Candle.NS_Fire_Candle",
                    }) do
                        ns = StaticFindObject(p)
                        if not (ns and ns:IsValid()) then ns = LoadAsset(p) end
                        if ns and ns:IsValid() then nsPath = p break end
                    end
                    if not (ns and ns:IsValid()) then log("FP: rag - no fire asset loadable") return end
                    local rag = owner:AddComponentByClass(ncClass, true, idT, false)
                    if not (rag and rag:IsValid()) then log("FP: rag - AddComponentByClass failed") return end
                    rag:SetAsset(ns, true)   -- UE5.5: 2nd param = bResetExistingOverrideParameters
                    pcall(function() rag:SetFirstPersonPrimitiveType(1) end)
                    rag:K2_AttachToComponent(comp, FName("None"), 2, 2, 0, false)
                    rag:K2_SetRelativeLocation(
                        { X = 0, Y = 0, Z = (fp.midLocal and fp.midLocal.z or 12.7) * 2 }, false, {}, false)
                    pcall(function() rag:Activate(true) end)
                    fp.rag = rag
                    log("FP: rag flame lit (" .. nsPath:match("([^/]+)$") .. ")")
                end)
                if not ragOk then log("FP: rag ERR: " .. tostring(ragErr)) end
                log("FP: bottle on " .. (target == mesh and "grenade" or "body") .. " bone " .. tostring(bone))
                local an = fp.animName
                ExecuteInGameThreadWithDelay(600, function()   -- re-sample once the raise anim settles
                    ExecuteInGameThread(function()
                        if objAlive(fp.bottle) and fp.animName == an then
                            sampleGrenadeBase("settled")
                            if lockedBase then fp.welded = nil end   -- re-weld off the settled pose
                        end
                    end)
                end)
            end)
            if not ok then log("FP swap ERR: " .. tostring(err)) end
        end)
    end)
end

-- FP swap mothballed: MeshPrototypeSID = MolotovBottle_Skeletal (cooked SK bottle on the
-- grenade skeleton, from the ZoneGrenades asset plugin) renders in-hand natively now.
local FP_SWAP_ENABLED = false

-- Flame-only path: the visible weapon mesh IS the bottle now, so the rag flame
-- attaches straight to its grenade bone — no spawn/weld/track machinery.
-- Retired 2026-10-21; A/B'd again 2026-10-22 — user verdict: sits weird in FP,
-- not the remembered look. Baked geometry flame stays the real path.
local FLAME_ENABLED = false
-- bottle bone space: jnt_offset at origin, base -12.9, mouth/rag +13.4
local FLAME_OFF = { X = 0, Y = 0, Z = 14 }
-- INS cycles: 1 wpn-bone+FPflag, 2 wpn-bone raw, 3 hand-bone+FPflag, 4 hand-bone raw
-- default 3: weapon-mesh bones stop pushing child transforms during montages,
-- so the flame froze mid-throw; the body rig's hand bone animates through all of them
local FLAME_VARIANT = 3
local function lightFlame(anim, variant)
    local ok, err = pcall(function()
        if not (anim and anim:IsValid()) then return end
        local mesh
        pcall(function() mesh = anim:GetOwningComponent() end)
        if not (mesh and mesh:IsValid()) then
            pcall(function() mesh = anim:GetOuter() end)
        end
        if not (mesh and mesh:IsValid()) then log("FP: no hands mesh for flame") return end
        fpRestore()
        fp.flameAnim = anim   -- after fpRestore: it wipes the stash
        local owner = mesh:GetOwner()
        local ncClass = StaticFindObject("/Script/Niagara.NiagaraComponent")
        if not (ncClass and ncClass:IsValid() and owner and owner:IsValid()) then
            log("FP: flame prereqs missing")
            return
        end
        local ns, nsPath
        -- candle first: a fuel-soaked rag is a small sooty torch, not a bonfire
        for _, p in ipairs({
            "/Game/_Stalker_2/VFX/Environment/Fire/Niagara/NS_Fire_Candle_2.NS_Fire_Candle_2",
            "/Game/_Stalker_2/VFX/Environment/Fire/Niagara/NS_Fire_Candle.NS_Fire_Candle",
            "/Game/_Stalker_2/VFX/Environment/Fire/Niagara/NS_Fire_Kerosene_2.NS_Fire_Kerosene_2",
        }) do
            ns = StaticFindObject(p)
            if not (ns and ns:IsValid()) then ns = LoadAsset(p) end
            if ns and ns:IsValid() then nsPath = p break end
        end
        if not (ns and ns:IsValid()) then log("FP: flame - no fire asset loadable") return end
        local target, bone = mesh, pickGrenadeBone(mesh)
        if variant >= 3 then   -- body rig: the proven-rendering parent from the old swap
            local parent, parentSock
            pcall(function() parent = mesh:GetAttachParent() end)
            pcall(function()
                local s = mesh:GetAttachSocketName()
                parentSock = tostring(s and s.ToString and s:ToString() or s)
            end)
            if parent and parent:IsValid() then
                local hb = pickHandBone(parent, parentSock)
                if hb then target, bone = parent, hb end
            end
        end
        local idT = { Rotation = { X = 0, Y = 0, Z = 0, W = 1 },
                      Translation = { X = 0, Y = 0, Z = 0 },
                      Scale3D = { X = 1, Y = 1, Z = 1 } }
        local rag = owner:AddComponentByClass(ncClass, true, idT, false)
        if not (rag and rag:IsValid()) then log("FP: flame - AddComponentByClass failed") return end
        rag:SetAsset(ns, true)
        if variant % 2 == 1 then
            pcall(function() rag:SetFirstPersonPrimitiveType(1) end)   -- 1 = FirstPerson
        end
        rag:K2_AttachToComponent(target, FName(bone or "None"), 2, 2, 0, false)
        rag:K2_SetRelativeLocation({ X = FLAME_OFF.X, Y = FLAME_OFF.Y, Z = FLAME_OFF.Z }, false, {}, false)
        -- batched Niagara sim pauses when the FP-flagged parent fails its render heuristic
        pcall(function() rag:SetForceSolo(true) end)
        pcall(function() rag:Activate(true) end)
        fp.rag, fp.mesh, fp.animName = rag, mesh, anim:GetFullName()
        log(string.format("FP: rag flame lit v%d on %s (%s)", variant, tostring(bone),
            nsPath:match("([^/]+)$")))
    end)
    if not ok then log("FP flame ERR: " .. tostring(err)) end
end
local function fpFlame(anim)
    ExecuteInGameThreadWithDelay(300, function()
        ExecuteInGameThread(function()
            local sid = mainHandSID()
            if not (sid:find("Molotov") or sid == "unreadable") then return end
            lightFlame(anim, FLAME_VARIANT)
        end)
    end)
end

RegisterKeyBind(Key.DEL, function()   -- Lua flame variant cycler (retired fallback)
    ExecuteInGameThread(function()
        FLAME_VARIANT = FLAME_VARIANT % 4 + 1
        local anim = objAlive(fp.flameAnim) and fp.flameAnim or nil
        if anim then
            lightFlame(anim, FLAME_VARIANT)
        else
            log("FP: DEL - no live hands anim to relight")
        end
    end)
end)

local function flameNudge(axis, d)
    ExecuteInGameThread(function()
        local rag = objAlive(fp.rag) and fp.rag or nil
        if not rag then return end
        FLAME_OFF[axis] = FLAME_OFF[axis] + d
        rag:K2_SetRelativeLocation(
            { X = FLAME_OFF.X, Y = FLAME_OFF.Y, Z = FLAME_OFF.Z }, false, {}, false)
        log(string.format("FP: flame off X=%g Y=%g Z=%g", FLAME_OFF.X, FLAME_OFF.Y, FLAME_OFF.Z))
    end)
end
RegisterKeyBind(Key.UP_ARROW, function() flameNudge("X", 3) end)
RegisterKeyBind(Key.DOWN_ARROW, function() flameNudge("X", -3) end)
RegisterKeyBind(Key.LEFT_ARROW, function() flameNudge("Y", -3) end)
RegisterKeyBind(Key.RIGHT_ARROW, function() flameNudge("Y", 3) end)
RegisterKeyBind(Key.PAGE_UP, function() flameNudge("Z", 3) end)
RegisterKeyBind(Key.PAGE_DOWN, function() flameNudge("Z", -3) end)

-- In-hands rag ragdoll: the cooked PA marks jnt_fuse Simulated, but the game's
-- pooled WeaponInHandsMesh comp may never create physics state (collision off)
-- — kick it per equip. Readback-gated retry; forces PhysicsOnly collision once
-- if the first kick lands on no bodies (PA bodies have collision disabled).
local kickRagPhysics
kickRagPhysics = function(anim, attempt, generation)
    generation = generation or equipGeneration
    ExecuteInGameThreadWithDelay(attempt == 1 and 250 or 400, function()
        ExecuteInGameThread(function()
            if generation ~= equipGeneration then return end
            local simulating = false
            pcall(function()
                local mesh = currentRagMesh(anim)
                if not mesh then return end
                local sid = "GrenadeMolotov"
                mesh:SetAllBodiesBelowSimulatePhysics(FName("jnt_fuse"), true, true)
                mesh:SetAllBodiesBelowPhysicsBlendWeight(FName("jnt_fuse"), 1.0, false, true)
                pcall(function() simulating = mesh:IsSimulatingPhysics(FName("jnt_fuse")) end)
                -- physics owns the hands rag now: kill the material droop (rag WPO
                -- default 5.0 stacks on bone motion = vertex spikes; tip card default
                -- 3.5 = the floating artifact). MID-wrapped slots are ours from a
                -- prior pass - set directly instead of chain-wrapping.
                local zeroed = 0
                for i = 0, mesh:GetNumMaterials() - 1 do
                    local m = mesh:GetMaterial(i)
                    local mfn = (m and m:IsValid()) and m:GetFullName() or ""
                    local mid
                    if mfn:find("MaterialInstanceDynamic", 1, true) then
                        mid = m
                    elseif mfn:find("MolotovRag", 1, true) or mfn:find("RagFlame", 1, true) then
                        mid = mesh:CreateDynamicMaterialInstance(i, m, FName("None"))
                    end
                    if mid and mid:IsValid() then
                        mid:SetScalarParameterValue(FName("DroopStrength"), 0.0)
                        zeroed = zeroed + 1
                    end
                end
                log("rag physics: kick attempt " .. attempt .. " sid=" .. sid
                    .. " simulating=" .. tostring(simulating) .. " droop0=" .. zeroed)
                if not simulating and attempt >= 3 and sid:find("Molotov") then
                    -- no physics state at all: PhysicsOnly wakes it (2 = ECollisionEnabled)
                    pcall(function() mesh:SetCollisionEnabled(2) end)
                end
            end)
            if not simulating and attempt < 4 then kickRagPhysics(anim, attempt + 1, generation) end
        end)
    end)
end

-- Rag surface fire: the player-burn system's emitters sample their attach
-- parent's skeletal mesh (NiagaraDataInterfaceSkeletalMesh), so attached to
-- the bottle mesh the fire crawls the swinging rag itself. No sound loop.
-- Mesh-sampling means it clusters on dense geometry (neck/plug) wherever the
-- component sits — the TIP flame is a POSITIONAL system instead, parked on
-- jnt_fuse_end (a real bone at the hem, courtesy of the FBX leaf-tail fix).
local RAG_FIRE_ENABLED = true
local RAG_FIRE_ASSETS = {
    "/Game/_Stalker_2/VFX/Player/NS_Character_Fire.NS_Character_Fire",
    "/Game/_Stalker_2/VFX/Anomalies/ClassicFire/Niagara/NS_ClassicFireNPCBurning.NS_ClassicFireNPCBurning",
}
local TIP_FIRE_ASSETS = {
    -- candle first: kerosene is a campfire-scale fuel-pool system (the Bane look)
    "/Game/_Stalker_2/VFX/Environment/Fire/Niagara/NS_Fire_Candle_2.NS_Fire_Candle_2",
    "/Game/_Stalker_2/VFX/Environment/Fire/Niagara/NS_Fire_Candle.NS_Fire_Candle",
    "/Game/_Stalker_2/VFX/Environment/Fire/Niagara/NS_Fire_Kerosene_2.NS_Fire_Kerosene_2",
}
local function loadFirst(paths)
    for _, p in ipairs(paths) do
        local a = StaticFindObject(p)
        if not (a and a:IsValid()) then a = LoadAsset(p) end
        if a and a:IsValid() then return a, p end
    end
end
local ragFire
ragFire = function(anim, attempt, generation)
    generation = generation or equipGeneration
    ExecuteInGameThreadWithDelay(attempt == 1 and 400 or 500, function()
        ExecuteInGameThread(function()
            if generation ~= equipGeneration then return end
            local ok, err = pcall(function()
                if objAlive(fp.rag) then return end
                local mesh = currentRagMesh(anim)
                if not mesh then return end
                local owner = mesh:GetOwner()
                local ncClass = StaticFindObject("/Script/Niagara.NiagaraComponent")
                if not (ncClass and ncClass:IsValid() and owner and owner:IsValid()) then return end
                local ns, nsPath = loadFirst(RAG_FIRE_ASSETS)
                if not (ns and ns:IsValid()) then log("ragfire: no system loadable") return end
                local tipNs, tipPath = loadFirst(TIP_FIRE_ASSETS)
                local idT = { Rotation = { X = 0, Y = 0, Z = 0, W = 1 },
                              Translation = { X = 0, Y = 0, Z = 0 },
                              Scale3D = { X = 1, Y = 1, Z = 1 } }
                local function lightAt(bone, rotRule, asset)
                    local comp = owner:AddComponentByClass(ncClass, true, idT, false)
                    if not (comp and comp:IsValid()) then return nil end
                    comp:SetAsset(asset or ns, true)
                    pcall(function() comp:SetFirstPersonPrimitiveType(1) end)
                    -- chain links' bone frames roll with the hang line and the system's
                    -- authored emitter offsets rotate with them (fire floated off the
                    -- cloth) — rotRule 1 = KeepWorld pins the frame upright
                    comp:K2_AttachToComponent(mesh, FName(bone), 2, rotRule or 2, 0, false)
                    comp:K2_SetRelativeLocation({ X = 0, Y = 0, Z = 0 }, false, {}, false)
                    pcall(function() comp:SetForceSolo(true) end)   -- batched sim pauses on FP parents
                    pcall(function() comp:Activate(true) end)
                    -- smoke off on the HELD fire only: it is a lit translucent sprite
                    -- spawning at the rag bone, so sprinting pushes the camera through it
                    -- and blanks the view for a frame. Must follow Activate — SetEmitterEnable
                    -- before the system is live is a silent no-op.
                    pcall(function() comp:SetEmitterEnable(FName("smoke"), false) end)
                    return comp
                end
                -- jnt_fuse = mouth anchor: the mesh-sampling blaze. Tip = positional
                -- flame on the hem-end bone; follows the swinging tip exactly.
                local comp = lightAt("jnt_fuse")
                if not comp then log("ragfire: AddComponentByClass failed") return end
                local lower = {}
                if tipNs then
                    local c = lightAt("jnt_fuse_end", 1, tipNs)
                    if c then lower[#lower + 1] = c end
                end
                fp.rag, fp.mesh, fp.animName = comp, mesh, anim:GetFullName()
                fp.ragLower = lower   -- wrappers; douse resolves via objAlive
                mp.cur = {}
                log(string.format("ragfire: lit attempt %d (%s + tip %s)", attempt,
                    nsPath:match("([^/]+)$"), tipPath and tipPath:match("([^/]+)$") or "none"))
            end)
            if not ok then log("ragfire ERR: " .. tostring(err)) end
            if not objAlive(fp.rag) and attempt < 5 then ragFire(anim, attempt + 1, generation) end
        end)
    end)
end

douseRagFire = function(why)
    equipGeneration = equipGeneration + 1
    mp.cur = {}
    if not fp.rag then return end
    local rag, lower = fp.rag, fp.ragLower
    fp.rag, fp.ragLower = nil, nil
    ExecuteInGameThread(function()
        pcall(function()
            if objAlive(rag) then rag:Deactivate() rag:K2_DestroyComponent(rag) end
        end)
        for _, c in ipairs(lower or {}) do
            pcall(function()
                if objAlive(c) then c:Deactivate() c:K2_DestroyComponent(c) end
            end)
        end
        log("ragfire: doused (" .. tostring(why) .. ")")
    end)
end

-- ===== pin-pull splice =====
-- The throw runs RGD5 montages whose first section is literally named "TearOff":
-- the pin yank, on a bottle that has no pin. GSC authored it as its own section on
-- both the weapon and the body montage, so the cut point is read from the asset
-- rather than guessed (0.500s two-handed, 0.833s with the detector up).
--   jump = start at the section boundary; the montage blend-in covers the pose change
--   warp = play TearOff at MP_WARP_RATE instead, which cuts nothing and still fires
--          every notify, so it is the fallback if skipping breaks the throw
-- Also logs "mp,<who>,<pos>,<rate>,<section>,<x>,<y>,<z>,<hands>,<pop>" per frame.
local MP_ENABLED   = true
local MP_VERBOSE   = false    -- per-frame CSV + section/notify dumps + debug keys
local MP_MODE      = "jump"   -- off | jump | warp
local MP_WARP_RATE = 6.0
local MP_STEP      = 1 / 30
local MP_MAX_LINES = 400      -- per montage, so a looping one cannot flood the log
local MP_TEAR      = "tearoff"

local function mpNum(s, prop)
    local v
    if not pcall(function() v = s[prop] end) then return -1 end
    return type(v) == "number" and v or -1
end

local function mpFName(s, prop)
    local v = "?"
    pcall(function() v = s[prop]:ToString() end)
    return v
end

local function mpShort(o)
    local n = "?"
    pcall(function()
        local f = o:GetFullName()
        n = f:match("([^%.]+)$") or f
    end)
    return n
end

local function mpDump(who, m)
    local len = mpNum(m, "SequenceLength")
    if len < 0 then pcall(function() len = m:GetPlayLength() end) end
    log(string.format("mp: >>> %s %s len=%.3f", who, mpShort(m), len))
    pcall(function()
        m.CompositeSections:ForEach(function(i, e)
            local s = e:get()
            log(string.format("mp:   sec[%s] %s begin=%.3f link=%.3f seglen=%.3f",
                tostring(i), mpFName(s, "SectionName"), mpNum(s, "SegmentBeginTime"),
                mpNum(s, "LinkValue"), mpNum(s, "SegmentLength")))
        end)
    end)
    pcall(function()
        m.Notifies:ForEach(function(i, e)
            local n = e:get()
            log(string.format("mp:   ntf[%s] %s t=%.3f dur=%.3f",
                tostring(i), mpFName(n, "NotifyName"), mpNum(n, "LinkValue"),
                mpNum(n, "Duration")))
        end)
    end)
end

-- End of the pin-pull section; nil for montages that have none (equip, detector).
local function mpTearEnd(m)
    local at
    pcall(function()
        m.CompositeSections:ForEach(function(_, e)
            local s = e:get()
            if mpFName(s, "SectionName"):lower() == MP_TEAR then
                local b, l = mpNum(s, "SegmentBeginTime"), mpNum(s, "SegmentLength")
                if b >= 0 and l > 0 then at = b + l end
            end
        end)
    end)
    return at
end

local function mpBones(who, mesh)
    if mp.bones[who] then return mp.bones[who] end
    local b = {}
    pcall(function()
        local n = mesh:GetNumBones()
        for i = 0, n - 1 do
            local bn = mesh:GetBoneName(i):ToString():lower()
            if not b.l and bn:find("l_hand") then b.l = bn end
            if not b.r and bn:find("r_hand") then b.r = bn end
            if b.l and b.r then break end
        end
    end)
    mp.bones[who] = b
    log(string.format("mp: %s hands l=%s r=%s", who, tostring(b.l), tostring(b.r)))
    return b
end

local function mpBoneLoc(mesh, bone)
    if not bone then return 0, 0, 0 end
    local v
    if pcall(function() v = mesh:GetBoneLocation(FName(bone), 1) end) and v then   -- 1 = component space
        return v.X or 0, v.Y or 0, v.Z or 0
    end
    if not mp.spaceWarned then
        mp.spaceWarned = true
        log("mp: component-space bone read failed - world space, stand still while sampling")
    end
    pcall(function() v = mesh:GetSocketLocation(FName(bone)) end)
    if v then return v.X or 0, v.Y or 0, v.Z or 0 end
    return 0, 0, 0
end

local function mpDist(ax, ay, az, bx, by, bz)
    local dx, dy, dz = ax - bx, ay - by, az - bz
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function mpWatch(who, inst, mesh)
    local m
    pcall(function() m = inst:GetCurrentActiveMontage() end)
    if not (m and m:IsValid()) then
        mp.cur[who] = nil
        return
    end

    local name, st = mpShort(m), mp.cur[who]
    if not st or st.name ~= name then
        st = { name = name, n = 0, tear = mpTearEnd(m) }
        mp.cur[who] = st
        if MP_VERBOSE then mpDump(who, m) end
        if st.tear then
            if MP_VERBOSE then
                log(string.format("mp: %s TearOff ends %.3f - %s", who, st.tear, MP_MODE))
            end
            if MP_MODE == "jump" then
                -- land just inside TearOff: letting the engine leave the section keeps
                -- whatever next-section branch the throw input already queued
                pcall(function() inst:Montage_SetPosition(m, st.tear - 0.002) end)
            elseif MP_MODE == "warp" then
                st.warping = pcall(function() inst:Montage_SetPlayRate(m, MP_WARP_RATE) end)
            end
        end
    end

    if not (MP_VERBOSE or mp.freeze or st.warping or st.frozen) then return end

    local pos, rate = -1, -1
    pcall(function() pos = inst:Montage_GetPosition(m) end)
    pcall(function() rate = inst:Montage_GetPlayRate(m) end)

    if st.warping and pos >= (st.tear or 0) - 0.05 then
        st.warping = false
        pcall(function() inst:Montage_SetPlayRate(m, 1.0) end)
    end

    if mp.freeze then
        st.frozen = true
        pcall(function() inst:Montage_SetPlayRate(m, 0.0) end)
        if mp.step ~= 0 then
            pcall(function() inst:Montage_SetPosition(m, math.max(0, pos + mp.step)) end)
        end
    elseif st.frozen then
        st.frozen = false
        pcall(function() inst:Montage_SetPlayRate(m, 1.0) end)
    end

    st.n = st.n + 1
    if not MP_VERBOSE or st.n > MP_MAX_LINES then return end

    local sec = "?"
    pcall(function() sec = inst:Montage_GetCurrentSection(m):ToString() end)
    local b = mpBones(who, mesh)
    local lx, ly, lz = mpBoneLoc(mesh, b.l)
    local rx, ry, rz = mpBoneLoc(mesh, b.r)
    if not st.ref then st.ref = { lx, ly, lz, rx, ry, rz } end
    local r = st.ref
    log(string.format("mp,%s,%.3f,%.2f,%s,%.1f,%.1f,%.1f,%.1f,%.1f",
        who, pos, rate, sec, lx, ly, lz,
        mpDist(lx, ly, lz, rx, ry, rz),
        mpDist(lx, ly, lz, r[1], r[2], r[3]) + mpDist(rx, ry, rz, r[4], r[5], r[6])))
end

local function mpTick()
    if not objAlive(fp.rag) then return end   -- our molotov is the only thing worth sampling
    local wm = objAlive(fp.mesh) and fp.mesh or nil
    if not (wm and wm:IsValid()) then return end
    local ai, body
    pcall(function() ai = wm.AnimScriptInstance end)
    if ai and ai:IsValid() then pcall(mpWatch, "wpn", ai, wm) end
    pcall(function() body = wm:GetAttachParent() end)
    if body and body:IsValid() then
        local bi
        pcall(function() bi = body.AnimScriptInstance end)
        if bi and bi:IsValid() then pcall(mpWatch, "body", bi, body) end
    end
    mp.step = 0
end

local function mpHook()
    if mp.hooked then return end
    mp.hooked = pcall(function()
        RegisterHook(HUD_TICK_HOOK, function()
            if not mp.alive then
                mp.alive = true
                log("mp: HUD tick alive")   -- registration success is NOT proof it fires
            end
            pcall(mpTick)
        end)
    end)
    log("mp: montage probe " .. (mp.hooked and ("armed, mode " .. MP_MODE) or "hook FAILED"))
end

-- fallback driver: the 2026-10-26 patch killed the stat-panel Tick (hook "armed"
-- but never fired — pin-pull returned silently). Poll at hover-mirror cadence
-- while the bottle is lit; mpWatch's montage-name latch makes double-driving
-- idempotent if the HUD hook ever comes back.
LoopInGameThreadWithDelay(60, function()
    if MP_ENABLED and fp.rag then
        ExecuteInGameThread(function() pcall(mpTick) end)
    end
    return false
end)

-- plain-data intents only: UObject work from a keybind races the per-frame hook
local MP_MODES = { "off", "jump", "warp" }
local function mpCycleMode()
    local i = 1
    for n, v in ipairs(MP_MODES) do if v == MP_MODE then i = n end end
    MP_MODE = MP_MODES[(i % #MP_MODES) + 1]
    log("mp: mode -> " .. MP_MODE)
end

local function mpBind(name, k, fn)
    if not k then return name .. "=MISSING" end
    return name .. (pcall(function() RegisterKeyBind(k, fn) end) and "=ok" or "=FAILED")
end
if MP_ENABLED and MP_VERBOSE then
    log("mp: keys " .. table.concat({
        mpBind("\\mode", Key.OEM_FIVE, mpCycleMode),
        mpBind("[freeze", Key.OEM_FOUR, function() mp.freeze = not mp.freeze end),
        mpBind("]step", Key.OEM_SIX, function() mp.step = MP_STEP end),
    }, " "))
end

local fpAnimSeen = {}
LoopInGameThreadWithDelay(120, function()
    ExecuteInGameThread(function()
        pcall(function()
            for _, anim in ipairs(FindAllOf("AnimBP_Rgd5_fp_C") or {}) do
                if anim:IsValid() and not anim:GetFullName():find("Default__") then
                    local a = regAddr(anim)
                    if a and not fpAnimSeen[a] then
                        if currentRagMesh(anim) then
                            fpAnimSeen[a] = true
                            equipGeneration = equipGeneration + 1
                            if MP_ENABLED then mpHook() end
                            kickRagPhysics(anim, 1)
                            if RAG_FIRE_ENABLED then ragFire(anim, 1) end
                            if FP_SWAP_ENABLED then
                                hookGrenadeTick()
                                fpSwap(anim, 1)
                            elseif FLAME_ENABLED then
                                fpFlame(anim)
                            end
                        end
                    end
                end
            end
        end)
    end)
    return false
end)

-- Un-swap when the hands anim changes (lowered / thrown / weapon switched).
LoopInGameThreadWithDelay(500, function()
    if not (fp.bottle or fp.rag) then return false end
    ExecuteInGameThread(function()
        local keep = false
        pcall(function()
            if objAlive(fp.mesh)
                    and (objAlive(fp.bottle) or objAlive(fp.rag)) then
                local cur = fp.mesh.AnimScriptInstance
                keep = cur and cur:IsValid() and cur:GetFullName() == fp.animName
            end
        end)
        if (fp.bottle or fp.rag) and not keep then
            log("FP: hands changed - bottle away")
            fpRestore()
        end
    end)
    return false
end)

-- Finds a live (non-CDO) instance of a native class; the console managers are
-- only usable this way.
local function liveInstance(className)
    local all = FindAllOf(className)
    if all then
        for _, o in ipairs(all) do
            -- skip the CDO: calling spawn helpers on it null-derefs (no world)
            if o:IsValid() and not o:GetFullName():find("Default__") then return o end
        end
    end
    return nil
end

-- Holding the lit bottle singes: slow HP drain while the rag fire burns in hand.
-- Gate = fp.rag (the Niagara fire is literally lit; douse paths clear it on throw
-- and holster). The floor keeps carelessness painful but never lethal.
--
-- Silent by construction. Every *damage* route has feedback welded on engine-side:
-- Burn brings the fire roar + red screen edges, Strike brings Skif's pain grunt on
-- every tick. Obj:ForceSetHP writes HP straight in, skipping the damage pipeline
-- entirely, so nothing reacts to it. ObjGetHP reads float but ForceSetHP takes
-- int32 — fractional ticks bank in `debt` and land as whole points.
local HOLD_BURN_ENABLED = true
local HOLD_BURN_HP = 0.5         -- per tick
local HOLD_BURN_PERIOD = 1500    -- ms between ticks (~0.33 HP/s)
local HOLD_BURN_FLOOR = 8.0      -- stop singeing below this HP
local holdBurn = { n = 0, probed = false, debt = 0 }

local holdBurnTimer
holdBurnTimer = LoopInGameThreadWithDelay(HOLD_BURN_PERIOD, function()
    if not HOLD_BURN_ENABLED then
        CancelDelayedAction(holdBurnTimer)
        return
    end
    if not fp.rag then
        holdBurn.n, holdBurn.probed, holdBurn.debt = 0, false, 0
        return false
    end
    ExecuteInGameThread(function()
        pcall(function()
            if not objAlive(fp.rag) then return end
            local cm = StaticFindObject("/Script/Stalker2.Default__CppMediator")
            local pawn
            pcall(function() pawn = UEHelpers.GetPlayerController().Pawn end)
            -- every exit here is silent, so say which piece is missing
            if not holdBurn.probed then
                holdBurn.probed = true
                log(string.format("hold-burn: probe cm=%s pawn=%s",
                    tostring(cm ~= nil), tostring(pawn ~= nil)))
            end
            if not (cm and cm:IsValid() and pawn and pawn:IsValid()) then return end
            local hp = cm:ObjGetHP(pawn)
            if type(hp) ~= "number" or hp <= HOLD_BURN_FLOOR then return end

            holdBurn.debt = holdBurn.debt + HOLD_BURN_HP
            local whole = math.floor(holdBurn.debt)
            if whole < 1 then return end
            holdBurn.debt = holdBurn.debt - whole

            local target = math.max(math.floor(HOLD_BURN_FLOOR), math.floor(hp) - whole)
            if not pcall(function() pawn:ForceSetHP(target) end) then
                HOLD_BURN_ENABLED = false
                log("hold-burn: ForceSetHP rejected - singe disabled")
                return
            end
            holdBurn.n = holdBurn.n + 1
            if holdBurn.n == 1 or holdBurn.n % 10 == 0 then
                log(string.format("hold-burn: tick %d  hp %.1f -> %d",
                    holdBurn.n, hp, target))
            end
        end)
    end)
    return false
end)

local function posStep() return fineStep and 0.5 or 2 end
local function rotStep() return fineStep and 5 or 15 end

-- fold a camera-relative world move (fwd/right/up) into bone-frame xyz deltas
local function camNudge(which, sign)
    local ok, err = pcall(function()
        local bottle, anchor = fpBottle(), fpAnchor()
        if not (bottle and anchor) then return end
        local kml = StaticFindObject("/Script/Engine.Default__KismetMathLibrary")
        local rot = UEHelpers.GetPlayerController():GetControlRotation()
        local v
        if which == "fwd" then v = kml:GetForwardVector(rot)
        elseif which == "right" then v = kml:GetRightVector(rot)
        else v = kml:GetUpVector(rot) end
        local sockRot = anchor:GetSocketRotation(FName(fp.boneName or "None"))
        local sf = kml:GetForwardVector(sockRot)
        local sr = kml:GetRightVector(sockRot)
        local su = kml:GetUpVector(sockRot)
        local step = sign * posStep()
        local function r1(x) return math.floor(x * 10 + 0.5) / 10 end
        bottleOff.x = r1(bottleOff.x + step * (v.X * sf.X + v.Y * sf.Y + v.Z * sf.Z))
        bottleOff.y = r1(bottleOff.y + step * (v.X * sr.X + v.Y * sr.Y + v.Z * sr.Z))
        bottleOff.z = r1(bottleOff.z + step * (v.X * su.X + v.Y * su.Y + v.Z * su.Z))
        applyBottleTune()
        logBottleOff("move " .. which .. (sign > 0 and "+" or "-") .. ":")
    end)
    if not ok then log("tune-move ERR: " .. tostring(err)) end
end

local function rotNudge(axis, sign)
    bottleOff[axis] = bottleOff[axis] + sign * rotStep()
    applyBottleTune()
    logBottleOff("rot " .. axis .. (sign > 0 and "+" or "-") .. ":")
end

consumeNudges = function()   -- runs inside the tick hook: game-thread, serialized
    if #nudgeQueue == 0 then return end
    local q = nudgeQueue
    nudgeQueue = {}
    for _, n in ipairs(q) do
        local kind = n[1]
        if kind == "cam" then
            camNudge(n[2], n[3])
        elseif kind == "rot" then
            rotNudge(n[2], n[3])
        elseif kind == "scale" then
            bottleOff.s = math.max(0.02, bottleOff.s + n[2] * (fineStep and 0.02 or 0.1))
            applyBottleTune()
            logBottleOff(n[2] > 0 and "scale+:" or "scale-:")
        elseif kind == "vis" then
            pcall(function()
                local b = fpBottle()
                if b then
                    fp.hiddenForPivot = not fp.hiddenForPivot
                    b:SetVisibility(not fp.hiddenForPivot, false)
                    log("bottle " .. (fp.hiddenForPivot and "hidden - pivot dot + hand disc exposed" or "shown"))
                end
            end)
        elseif kind == "lock" then
            if lockedBase then
                lockedBase = nil
                fp.welded = nil
                log("fidget pose UNLOCKED - live grenade-path tracking")
            elseif fp.baseLoc and fp.baseRot then
                lockedBase = {
                    loc = { x = fp.baseLoc.x, y = fp.baseLoc.y, z = fp.baseLoc.z },
                    rot = { p = fp.baseRot.p, yaw = fp.baseRot.yaw, r = fp.baseRot.r },
                }
                fp.welded = nil
                log(string.format(
                    "fidget pose LOCKED base loc %.1f %.1f %.1f rot %.1f %.1f %.1f - send this line + final state: to bake",
                    lockedBase.loc.x, lockedBase.loc.y, lockedBase.loc.z,
                    lockedBase.rot.p, lockedBase.rot.yaw, lockedBase.rot.r))
            end
        end
    end
    if lockedBase then fp.welded = nil end   -- tuner authored on the wrist; re-weld next tick
end

-- tiny bottle-mesh "dot" at the pivot + flat disc pinned ON the hand joint itself
-- (shipping builds compile out DrawDebug*, so markers are mesh clones)
showPivotMarker = function(on)
    pcall(function()
        if not on then
            pcall(function() if objAlive(fp.marker) then fp.marker:K2_DestroyComponent(fp.marker) end end)
            pcall(function() if objAlive(fp.handDot) then fp.handDot:K2_DestroyComponent(fp.handDot) end end)
            fp.marker, fp.handDot = nil, nil
            return
        end
        if objAlive(fp.marker) then return end
        local bottle, anchor = fpBottle(), fpAnchor()
        if not (bottle and anchor) then return end
        local mesh = StaticFindObject(BOTTLE_MESH_PATH)
        local smcClass = StaticFindObject("/Script/Engine.StaticMeshComponent")
        local owner = bottle:GetOwner()
        if not (mesh and mesh:IsValid() and smcClass and smcClass:IsValid()
                and owner and owner:IsValid()) then return end
        local idT = { Rotation = { X = 0, Y = 0, Z = 0, W = 1 },
                      Translation = { X = 0, Y = 0, Z = 0 },
                      Scale3D = { X = 1, Y = 1, Z = 1 } }
        local function spawnDot(scale)
            local m = owner:AddComponentByClass(smcClass, true, idT, false)
            if not (m and m:IsValid()) then return nil end
            m:SetStaticMesh(mesh)
            m:SetCollisionEnabled(0)
            pcall(function() m:SetFirstPersonPrimitiveType(1) end)
            m:K2_AttachToComponent(anchor, FName(fp.boneName or "None"), 2, 2, 0, false)
            m:SetRelativeScale3D(scale)
            return m
        end
        fp.marker = spawnDot({ X = 0.06, Y = 0.06, Z = 0.06 })      -- mini bottle = bottle pivot
        fp.handDot = spawnDot({ X = 0.5, Y = 0.5, Z = 0.04 })        -- flat disc = hand joint target
        applyBottleTune()   -- snaps pivot dot onto the pivot; disc stays at the bone origin
    end)
end

local function setTuneMode(on)
    tuneMode = on
    pcall(function()   -- trap WASD: block pawn movement while tuning
        local pc = UEHelpers.GetPlayerController()
        if on then pc:SetIgnoreMoveInput(true) else pc:ResetIgnoreMoveInput() end
    end)
    showPivotMarker(on)
    log("TUNE MODE " .. (on
        and "ON - movement locked | WASD move, PgUp/PgDn depth, Up/Dn scale, Lt/Rt roll, ,/. pitch, -/= yaw, K lock fidget pose, V peek pivot, End fine"
        or "OFF - movement restored"))
    if on then logBottleOff("state:") end
end

-- Pose is baked (rig weld) — tuner mothballed. Flip true to re-enable Home/End
-- and the tune keys; everything below stays intact but registers no keybinds.
local TUNE_ENABLED = false

if TUNE_ENABLED then
    RegisterKeyBind(Key.HOME, function()
        ExecuteInGameThread(function() setTuneMode(not tuneMode) end)
    end)

    RegisterKeyBind(Key.END, function()
        fineStep = not fineStep
        log("tune steps: " .. (fineStep and "FINE 0.5cm/5deg" or "coarse 2cm/15deg"))
    end)
end

local function tuneBind(key, fn)
    if not TUNE_ENABLED then return end
    RegisterKeyBind(key, function()
        if not tuneMode then return end
        fn()   -- push-only; the tick hook does the real work on the game thread
    end)
end

tuneBind(Key.W, function() queueNudge({ "cam", "up", 1 }) end)
tuneBind(Key.S, function() queueNudge({ "cam", "up", -1 }) end)
tuneBind(Key.A, function() queueNudge({ "cam", "right", -1 }) end)
tuneBind(Key.D, function() queueNudge({ "cam", "right", 1 }) end)
tuneBind(Key.PAGE_UP, function() queueNudge({ "cam", "fwd", -1 }) end)   -- toward camera
tuneBind(Key.PAGE_DOWN, function() queueNudge({ "cam", "fwd", 1 }) end)
tuneBind(Key.UP_ARROW, function() queueNudge({ "scale", 1 }) end)
tuneBind(Key.DOWN_ARROW, function() queueNudge({ "scale", -1 }) end)
tuneBind(Key.LEFT_ARROW, function() queueNudge({ "rot", "rx", -1 }) end)
tuneBind(Key.RIGHT_ARROW, function() queueNudge({ "rot", "rx", 1 }) end)
tuneBind(Key.OEM_COMMA, function() queueNudge({ "rot", "ry", -1 }) end)
tuneBind(Key.OEM_PERIOD, function() queueNudge({ "rot", "ry", 1 }) end)
tuneBind(Key.OEM_MINUS, function() queueNudge({ "rot", "rz", -1 }) end)
tuneBind(Key.OEM_PLUS, function() queueNudge({ "rot", "rz", 1 }) end)
tuneBind(Key.V, function() queueNudge({ "vis" }) end)
tuneBind(Key.K, function() queueNudge({ "lock" }) end)

-- Craft chain probes. Logs all three counts so a partial run (vodka taken but no
-- molotov) is distinguishable from the If gate refusing outright.
-- The backpack never repaints when items change underneath it, so a craft looks
-- like it did nothing until you close the screen. Nudge the live widget instead.
-- SortInventory would also rebuild but reorders the player's pack, so it is out.
-- Repaint the backpack after we edit it. Only ever called from the craft path,
-- where the player is demonstrably standing in an open inventory: the 3:10pm
-- crash came from bursting this during a firefight (bandaging moves the kit in
-- and out), poking a torn-down widget. pcall cannot catch that AV, so the guard
-- has to be "is it actually on screen", not a try/catch.
-- Only UpdateInputDependent: OnVisibilityChangedEvent is an engine-fed handler.
local function nudgeInventoryUI()
    local inv
    pcall(function() inv = liveInstance("InventoryNew") end)
    if not (inv and inv:IsValid()) then return end
    local visible = false
    pcall(function() visible = inv:IsVisible() end)
    if not visible then return end
    pcall(function() inv:UpdateInputDependent() end)
end

-- The quest chain lands one node at a time, so repaint across the whole window.
local function nudgeBurst(count, interval)
    for i = 0, count - 1 do
        ExecuteInGameThreadWithDelay(i * interval, function()
            ExecuteInGameThread(function() pcall(nudgeInventoryUI) end)
        end)
    end
end

local function craftFire(tag, sid, done)
    ExecuteInGameThread(function()
        local ok, err = pcall(function()
            local cm = StaticFindObject("/Script/Stalker2.Default__CppMediator")
            local aa = liveInstance("CustomConsoleManagerAA")
            local pawn
            pcall(function() pawn = UEHelpers.GetPlayerController().Pawn end)
            if not (aa and cm and cm:IsValid() and pawn and pawn:IsValid()) then
                log("craft: missing aa/cm/pawn")
                if done then done() end
                return
            end
            local function counts()
                return cm:GetItemsCountInInventory(pawn, "Vodka"),
                       cm:GetItemsCountInInventory(pawn, "Bandage"),
                       cm:GetItemsCountInInventory(pawn, "GrenadeMolotov")
            end
            local v0, b0, m0 = counts()
            log(string.format("craft[%s]: before vodka=%s bandage=%s molotov=%s",
                tag, tostring(v0), tostring(b0), tostring(m0)))
            local okC, errC = pcall(function() aa:XStartQuestNodeBySID(sid) end)
            if not okC then log("craft: call ERR " .. tostring(errC)) end
            nudgeBurst(12, 250)
            ExecuteInGameThreadWithDelay(900, function()
                ExecuteInGameThread(function()
                    -- re-resolve: the pawn wrapper from 900ms ago may be dead
                    local cm2 = StaticFindObject("/Script/Stalker2.Default__CppMediator")
                    local pawn2
                    pcall(function() pawn2 = UEHelpers.GetPlayerController().Pawn end)
                    local function counts()
                        return cm2:GetItemsCountInInventory(pawn2, "Vodka"),
                               cm2:GetItemsCountInInventory(pawn2, "Bandage"),
                               cm2:GetItemsCountInInventory(pawn2, "GrenadeMolotov")
                    end
                    if not (cm2 and cm2:IsValid() and pawn2 and pawn2:IsValid()) then
                        log("craft: follow-up lost cm/pawn")
                        if done then done() end
                        return
                    end
                    local v1, b1, m1 = counts()
                    log(string.format("craft[%s]: after  vodka=%s bandage=%s molotov=%s",
                        tag, tostring(v1), tostring(b1), tostring(m1)))
                    if type(m1) == "number" and type(m0) == "number" and m1 > m0 then
                        log("craft: SUCCESS - rag-wrapped a bottle")
                    else
                        log("craft: no molotov granted")
                    end
                    pcall(nudgeInventoryUI)
                    if done then done() end
                end)
            end)
        end)
        if not ok then
            log("craft ERR: " .. tostring(err))
            if done then done() end
        end
    end)
end

-- ===== "Make Molotov" context-menu entry =====
-- The craft lives in the inventory right-click menu now (kit retired 2026-11-02).
-- Menu rows are created per-open; MenuItemWidgetClass + CreateWidget + AddChild
-- renders a real row, but native code binds row button delegates only for ITS OWN
-- rows during population — a spawned row's click/hover events never dispatch
-- (probe-proven: three clicks, zero hook hits) and Lua cannot AddDynamic. So we
-- own the click: row:IsHovered() (callable native UFunction) + an LMB keybind.
local menuCraft = { entry = nil, busy = false, hovered = false }

-- The craft's quest nodes each fire a Received/Lost banner, and the queue drips
-- them out for ~10s. No cfg switch exists (quest prototypes carry only
-- LocalQuest; ItemRemove nodes have no silent flag).
-- DISABLED 2026-11-02: calling HideNotificationMain/TryShowNextNotify from a
-- 200ms loop AV'd in native code (null + 0x2e9) the first time a craft ran
-- while banners animated — pcall cannot catch native AVs. Do NOT re-enable
-- until the calls are probed one-by-one from the console against a live
-- banner. Until then the parade marches on.
local QUIET_BANNERS = false
local quietUntil = 0
local function quietBanners(seconds)
    if not QUIET_BANNERS then return end
    quietUntil = os.clock() + seconds
    local timer
    timer = LoopInGameThreadWithDelay(200, function()
        if os.clock() >= quietUntil then
            CancelDelayedAction(timer)
            return
        end
        ExecuteInGameThread(function()
            pcall(function()
                for _, nw in ipairs(FindAllOf("NotificationWidget") or {}) do
                    if nw:IsValid() and not nw:GetFullName():find("Default__") then
                        pcall(function() nw:HideNotificationMain() end)
                        pcall(function() nw:HideNotificationSecondary() end)
                        pcall(function() nw:TryShowNextNotify() end)
                    end
                end
            end)
        end)
        return false
    end)
end

local function playerCounts()
    local cm = StaticFindObject("/Script/Stalker2.Default__CppMediator")
    local pawn
    pcall(function() pawn = UEHelpers.GetPlayerController().Pawn end)
    if not (cm and cm:IsValid() and pawn and pawn:IsValid()) then return nil end
    local v = cm:GetItemsCountInInventory(pawn, "Vodka")
    local b = cm:GetItemsCountInInventory(pawn, "Bandage")
    if type(v) ~= "number" or type(b) ~= "number" then return nil end
    return v, b
end

local function injectCraftEntry(menu)
    local itemClass, box
    pcall(function() itemClass = menu.MenuItemWidgetClass end)
    pcall(function() box = menu.Menu end)
    if not (itemClass and box and box:IsValid()) then return end
    local v, b = playerCounts()
    if not (v and v >= 1 and b >= 1) then return end   -- no makings, no menu row
    local wbl = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
    local w = wbl:Create(menu, itemClass, nil)
    if not (w and w:IsValid()) then return end
    pcall(function() w.Label:SetText(FText("Craft molotov cocktail")) end)
    box:AddChild(w)
    -- the game styles rows inside its native hover handlers (the TextColor* copy
    -- did nothing: class defaults already match) — they're plain UFunctions, so
    -- drive them ourselves: settle into unhovered now, mirror IsHovered() after
    pcall(function() w:OnButtonUnHovered() end)
    menuCraft.entry, menuCraft.hovered = w, false
    log("craft: Molotov on the menu")
end

-- hover mirror: native rows get this from their bound delegates; ours is unbound
LoopInGameThreadWithDelay(60, function()
    if not menuCraft.entry then return false end
    ExecuteInGameThread(function()
        pcall(function()
            local e = objAlive(menuCraft.entry) and menuCraft.entry or nil
            if not e then menuCraft.entry = nil return end
            local hov = e:IsHovered()
            if hov ~= menuCraft.hovered then
                menuCraft.hovered = hov
                if hov then e:OnButtonHovered() else e:OnButtonUnHovered() end
            end
        end)
    end)
    return false
end)

local menuSeen = {}
LoopInGameThreadWithDelay(120, function()
    ExecuteInGameThread(function()
        pcall(function()
            for _, menu in ipairs(FindAllOf("W_RightClickMenu_C") or {}) do
                if menu:IsValid() and not menu:GetFullName():find("Default__") then
                    local menuAddr = regAddr(menu)
                    if menuAddr and not menuSeen[menuAddr] then
                        menuSeen[menuAddr] = true
                        menuCraft.entry = nil   -- stale row from a menu closed without a click
                        ExecuteInGameThreadWithDelay(50, function()
                            ExecuteInGameThread(function()
                                pcall(function()
                                    if objAlive(menu) then injectCraftEntry(menu) end
                                end)
                            end)
                        end)
                    end
                end
            end
        end)
    end)
    return false
end)

local function hideMenu()
    pcall(function()
        local inv = liveInstance("InventoryNew")
        if inv then inv:HideRightClickMenu() end
    end)
end

-- LMB fires on every trigger pull: the plain-field gate keeps combat cost at a nil check
RegisterKeyBind(Key.LEFT_MOUSE_BUTTON, function()
    if not menuCraft.entry or menuCraft.busy then return end
    ExecuteInGameThread(function()
        pcall(function()
            local entry = objAlive(menuCraft.entry) and menuCraft.entry or nil
            if not entry then
                menuCraft.entry = nil   -- menu died without a craft; re-cheapen the gate
                return
            end
            if not entry:IsHovered() then return end
            menuCraft.entry = nil
            local v, b = playerCounts()
            if not (v and v >= 1 and b >= 1) then hideMenu() return end
            menuCraft.busy = true
            log("craft: Make Molotov clicked")
            hideMenu()
            quietBanners(12)
            -- fire the removals directly: the If gate adds a hop and does not gate anyway
            craftFire("menu", "MolotovCraft_TakeVodka", function()
                menuCraft.busy = false
            end)
        end)
    end)
end)

-- F7 fires the chain directly (dev fallback if the kit watcher misses a use).
RegisterKeyBind(Key.F7, function()
    craftFire("hotkey", "MolotovCraft_Entry")
end)

-- F10: dev only — restock vodka for craft testing. The kit arrives on its own.
-- (F11 is the game's window toggle, F8 quickload, F5 quicksave.)
RegisterKeyBind(Key.F10, function()
    ExecuteInGameThread(function()
        local rk = liveInstance("CustomConsoleManagerRK")
        if not rk then return end
        pcall(function() rk:XCreateItemInInventoryByID("Vodka", 0, 5, 1.0) end)
        log("craft: +5 vodka")
        nudgeBurst(6, 250)
    end)
end)

-- F9: object dump without the CTRL+O GUI (no PDA conflict, no focus juggling)
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

-- F6: probe/load the fire class without needing a throw.
RegisterKeyBind(Key.F6, function()
    ExecuteInGameThread(function()
        log("F6 probe")
        local obj = StaticFindObject(FIRE_CLASS_PATH)
        log("StaticFind -> " .. ((obj and obj:IsValid()) and "LOADED" or "nil"))
        if not (obj and obj:IsValid()) then
            obj = LoadAsset(FIRE_CLASS_PATH)
            log("LoadAsset -> " .. ((obj and obj:IsValid()) and "OK" or "FAILED"))
        end
        local pc = UEHelpers.GetPlayerController()
        if obj and obj:IsValid() and pc and pc:IsValid() and pc.Pawn and pc.Pawn:IsValid() then
            local loc = pc.Pawn:K2_GetActorLocation()
            spawnGroundFire(loc.X + 400, loc.Y, loc.Z)   -- test fire 4m ahead-ish
        end
    end)
end)
