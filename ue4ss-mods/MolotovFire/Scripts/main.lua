local function log(msg) print("[MolotovFire] " .. msg .. "\n") end

log("loaded")

local UEHelpers = require("UEHelpers")

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
                    fires[#fires + 1] = { actor = actor, dieAt = os.clock() + life }
                    spawned = spawned + 1
                end
            end)
            if not ok then log("FIRE spawn error: " .. tostring(err)) end
        end
    end
    log(string.format("FIRE: %d patches burning at %.0f %.0f %.0f", spawned, x, y, z))
end

-- Extinguish expired fires.
LoopAsync(1000, function()
    if #fires == 0 then return false end
    ExecuteInGameThread(function()
        for i = #fires, 1, -1 do
            local f = fires[i]
            if os.clock() >= f.dieAt then
                pcall(function()
                    if f.actor:IsValid() then f.actor:K2_DestroyActor() end
                end)
                table.remove(fires, i)
            end
        end
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

-- Engine's TIMED detonation applies cfg ConcussionEffects; manual Explode() bypasses
-- that wrapper (NPCs flinched but never ignited) — so burn them via the cheat shard.
local function igniteNearby(x, y, z)
    local rk
    for _, o in ipairs(FindAllOf("CustomConsoleManagerRK") or {}) do
        if o:IsValid() and not o:GetFullName():find("Default__") then rk = o break end
    end
    local cm = StaticFindObject("/Script/Stalker2.Default__CppMediator")
    if not (rk and cm and cm:IsValid()) then log("ignite: no RK shard/CppMediator") return end
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
            local dx, dy, dz = loc.X - x, loc.Y - y, loc.Z - z
            if dx * dx + dy * dy + dz * dz > BURN_RADIUS * BURN_RADIUS then return end
            local uid = cm:GetGUID(npc)
            if type(uid) == "number" and uid ~= 0 then
                rk:XApplyEffectOnNPCByUID("MolotovBurning", uid)
                applied = applied + 1
            end
        end)
    end
    log(string.format("ignite: MolotovBurning applied to %d NPC(s)", applied))
end

local function detonate(t, grenade, x, y, z, how)
    if t.detonated then return end
    t.detonated = true
    if t.alive then
        t.alive = false
        trackedCount = trackedCount - 1
    end
    pcall(function()
        if grenade and grenade:IsValid() then grenade:Explode() end
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
            for _, t in ipairs(tracked) do
                if t.alive and t.armed and not t.detonated and not t.hitPending
                        and sameObj(t.actor, g) then
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
            if not (grenade and grenade:IsValid()) then done = true return end
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
            ExecuteWithDelay(50, function() tuneFlightLook(grenade, attempt + 1) end)
        end
    end)
end

local douseRagFire   -- fwd decl: fp lives below; assigned beside ragFire

NotifyOnNewObject("/Game/GameLite/Blueprints/Grenades/BP_grenade.BP_Grenade_C", function(grenade)
    tracked[#tracked + 1] = { actor = grenade, x = 0, y = 0, z = 0, alive = true, seen = 0 }
    trackedCount = trackedCount + 1
    log("grenade spawned (equipped)")
    -- the hand fire must not ride the arm after the bottle flies
    if douseRagFire then douseRagFire("thrown") end
    ExecuteWithDelay(16, function() tuneFlightLook(grenade, 1) end)
    -- dump: BP_Grenade_C has exactly one StaticMeshComponent, no skeletal
    ExecuteWithDelay(300, function()
        ExecuteInGameThread(function()
            local ok, err = pcall(function()
                if not (grenade and grenade:IsValid()) then log("bottleize: actor gone") return end
                -- gate: native Grenade.SID (dump: plain StrProperty) names the prototype
                local sid = "unreadable"
                pcall(function()
                    local v = grenade.SID
                    local s = tostring(v and v.ToString and v:ToString() or v)
                    if s ~= "" and s ~= "nil" then sid = s end
                end)
                log("bottleize: SID = " .. sid)
                if not (sid:find("Molotov") or sid == "unreadable") then
                    log("bottleize: not a molotov, skipping")
                    for _, t in ipairs(tracked) do
                        if t.alive and rawequal(t.actor, grenade) then
                            t.alive = false
                            trackedCount = trackedCount - 1
                            log("untracked non-molotov (no fire for RGD5/F1)")
                        end
                    end
                    return
                end
                -- mesh swap retired: cfg MeshInWorldPrototypeSID ships the bottle; a
                -- runtime SetStaticMesh rebuilt the physics body mid-flight and froze it
                log("bottleize: cfg mesh in use")
                -- flight look applied by tuneFlightLook from frame 1 (not here: quick
                -- throws land before this 300ms delay fires)
                -- NO live component sweeps here: FindAllOf over world mesh comps
                -- caused a native AV (uncatchable). FP-hands hunt moved to offline dumps.
            end)
            if not ok then log("bottleize ERR: " .. tostring(err)) end
        end)
    end)
end)

LoopAsync(100, function()
    if trackedCount == 0 then return false end
    ExecuteInGameThread(function()
        for _, t in ipairs(tracked) do
            if t.alive then
                local ok = pcall(function()
                    -- deferred impact: flagged by the OnHit hook, executed here
                    if t.hitPending and not t.detonated then
                        t.hitPending = nil
                        local sid, px, py, pz = "", t.x, t.y, t.z
                        if t.actor:IsValid() then
                            pcall(function()
                                local v = t.actor.SID
                                sid = tostring(v and v.ToString and v:ToString() or v)
                            end)
                            pcall(function()   -- resting spot = true ground zero
                                local loc = t.actor:K2_GetActorLocation()
                                if not (loc.X == 0 and loc.Y == 0 and loc.Z == 0) then
                                    px, py, pz = loc.X, loc.Y, loc.Z
                                end
                            end)
                        end
                        if sid:find("Molotov") then
                            detonate(t, t.actor, px, py, pz, "impact")
                            return
                        end
                        -- non-molotov slipped in pre-bottleize: engine timer keeps it
                    end
                    -- fallback fuse: soft landings (water/bushes) may never fire OnHit
                    if t.armed and os.clock() >= t.boomAt then
                        detonate(t, t.actor, t.x, t.y, t.z, "fuse fallback")
                        return
                    end
                    if t.actor:IsValid() then
                        local loc = t.actor:K2_GetActorLocation()
                        if (loc.X == 0 and loc.Y == 0 and loc.Z == 0) then
                            local root = t.actor.RootComponent
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

local function attachWrist()   -- snap back to the authoring frame (zero relative)
    fp.bottle:K2_AttachToComponent(fp.anchor, FName(fp.boneName or "None"), 2, 2, 0, false)
end

local function regrip()   -- KeepWorld re-attach: same world pose, short fist lever
    pcall(function()
        if not (fp.bottle and fp.bottle:IsValid() and fp.anchor and fp.anchor:IsValid()) then return end
        local grip
        for _, b in ipairs(GRIP_BONES) do
            if fp.anchor:DoesSocketExist(FName(b)) then grip = b break end
        end
        if not grip then return end
        fp.bottle:K2_AttachToComponent(fp.anchor, FName(grip), 1, 1, 1, false)
        if not fp.gripLogged then
            fp.gripLogged = true
            local rl, rr = fp.bottle.RelativeLocation, fp.bottle.RelativeRotation
            log(string.format("FP: riding %s rel %.1f %.1f %.1f rot %.1f %.1f %.1f",
                grip, rl.X, rl.Y, rl.Z, rr.Pitch, rr.Yaw, rr.Roll))
        end
    end)
end

local function applyBottleTune()
    pcall(function()
        if fp.bottle and fp.bottle:IsValid() then
            if fp.anchor and fp.anchor:IsValid() then attachWrist() end
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
            fp.bottle:SetRelativeScale3D({ X = bottleOff.s, Y = bottleOff.s, Z = bottleOff.s })
            fp.bottle:K2_SetRelativeLocation({ X = tx - ox, Y = ty - oy, Z = tz - oz }, false, {}, false)
            fp.bottle:K2_SetRelativeRotation(rot, false, {}, false)
            if fp.marker and fp.marker:IsValid() then   -- marker = the grip/mid point
                fp.marker:K2_SetRelativeLocation({ X = tx, Y = ty, Z = tz }, false, {}, false)
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
        if not (fp.bottle and fp.bottle:IsValid() and fp.mesh and fp.mesh:IsValid()) then return end
        attachWrist()   -- readback below must be wrist-relative (authoring frame)
        local gl = fp.mesh:GetSocketLocation(FName("jnt_wpn_rgd5"))
        local gr = fp.mesh:GetSocketRotation(FName("jnt_wpn_rgd5"))
        fp.bottle:K2_SetWorldLocationAndRotation(
            { X = gl.X, Y = gl.Y, Z = gl.Z },
            { Pitch = gr.Pitch, Yaw = gr.Yaw, Roll = gr.Roll }, false, {}, false)
        local rl, rr = fp.bottle.RelativeLocation, fp.bottle.RelativeRotation
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
    local g = fp.mesh:GetSocketLocation(FName("jnt_wpn_rgd5"))
    local function dist(bone)
        local h = fp.anchor:GetSocketLocation(FName(bone))
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
        if not (fp.bottle and fp.bottle:IsValid() and fp.mesh and fp.mesh:IsValid()) then return end
        sampleGrenadeBase(nil)
        fp.bottle:K2_AttachToComponent(fp.mesh, FName("jnt_wpn_rgd5"), 1, 1, 1, false)
        fp.welded = true
        if not fp.weldLogged then
            fp.weldLogged = true
            local rl, rr = fp.bottle.RelativeLocation, fp.bottle.RelativeRotation
            log(string.format("FP: welded to jnt_wpn_rgd5 rel %.1f %.1f %.1f rot %.1f %.1f %.1f",
                rl.X, rl.Y, rl.Z, rr.Pitch, rr.Yaw, rr.Roll))
        end
    end)
end

local function trackTick()
    if not (fp.bottle and fp.bottle:IsValid() and fp.mesh and fp.mesh:IsValid()
            and fp.anchor and fp.anchor:IsValid() and fp.anchor ~= fp.mesh) then return end
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
    pcall(function()
        if fp.mesh and fp.mesh:IsValid() then
            fp.mesh:SetVisibility(true, false)
            if fp.prevTick ~= nil then fp.mesh.VisibilityBasedAnimTickOption = fp.prevTick end
        end
    end)
    pcall(function()
        if fp.bottle and fp.bottle:IsValid() then fp.bottle:K2_DestroyComponent(fp.bottle) end
    end)
    pcall(function()
        if fp.marker and fp.marker:IsValid() then fp.marker:K2_DestroyComponent(fp.marker) end
    end)
    pcall(function()
        if fp.handDot and fp.handDot:IsValid() then fp.handDot:K2_DestroyComponent(fp.handDot) end
    end)
    pcall(function()
        if fp.rag and fp.rag:IsValid() then fp.rag:K2_DestroyComponent(fp.rag) end
    end)
    fp.bottle, fp.mesh, fp.animName, fp.prevTick = nil, nil, nil, nil
    fp.anchor, fp.boneName, fp.baseLoc, fp.baseRot = nil, nil, nil, nil
    fp.marker, fp.handDot, fp.hiddenForPivot, fp.leftLogged, fp.midLocal, fp.rag = nil, nil, nil, nil, nil, nil
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

local fpSwap   -- fwd-decl: equip swap retries while rig socket names are unreadable
fpSwap = function(anim, attempt)
    -- let the game finish wiring mesh+anim before restyling it
    ExecuteWithDelay(attempt == 1 and 150 or 400, function()
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
                ExecuteWithDelay(600, function()   -- re-sample once the raise anim settles
                    ExecuteInGameThread(function()
                        if fp.bottle and fp.bottle:IsValid() and fp.animName == an then
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
    ExecuteWithDelay(300, function()
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
        if fp.flameAnim and fp.flameAnim:IsValid() then
            lightFlame(fp.flameAnim, FLAME_VARIANT)
        else
            log("FP: DEL - no live hands anim to relight")
        end
    end)
end)

local function flameNudge(axis, d)
    ExecuteInGameThread(function()
        if not (fp.rag and fp.rag:IsValid()) then return end
        FLAME_OFF[axis] = FLAME_OFF[axis] + d
        fp.rag:K2_SetRelativeLocation(
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
kickRagPhysics = function(anim, attempt)
    ExecuteWithDelay(attempt == 1 and 250 or 400, function()
        ExecuteInGameThread(function()
            local simulating = false
            pcall(function()
                if not (anim and anim:IsValid()) then simulating = true return end
                local sid = mainHandSID()
                if not (sid:find("Molotov") or sid == "unreadable") then return end
                local mesh
                pcall(function() mesh = anim:GetOwningComponent() end)
                if not (mesh and mesh:IsValid()) then
                    pcall(function() mesh = anim:GetOuter() end)
                end
                if not (mesh and mesh:IsValid()) then return end
                -- advisory gate: only hard-skip on a KNOWN foreign mesh (accessor may not reflect)
                local fn = ""
                pcall(function() fn = tostring(mesh:GetSkeletalMeshAsset():GetFullName()) end)
                if fn ~= "" and not fn:find("SK_MolotovBottle", 1, true) then return end
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
            if not simulating and attempt < 6 then kickRagPhysics(anim, attempt + 1) end
        end)
    end)
end

-- Rag surface fire: the player-burn system's emitters sample their attach
-- parent's skeletal mesh (NiagaraDataInterfaceSkeletalMesh), so attached to
-- the bottle mesh the fire crawls the swinging rag itself. No sound loop.
local RAG_FIRE_ENABLED = true
local RAG_FIRE_ASSETS = {
    "/Game/_Stalker_2/VFX/Player/NS_Character_Fire.NS_Character_Fire",
    "/Game/_Stalker_2/VFX/Anomalies/ClassicFire/Niagara/NS_ClassicFireNPCBurning.NS_ClassicFireNPCBurning",
}
local ragFire
ragFire = function(anim, attempt)
    ExecuteWithDelay(attempt == 1 and 400 or 500, function()
        ExecuteInGameThread(function()
            local ok, err = pcall(function()
                if not (anim and anim:IsValid()) then return end
                if fp.rag and fp.rag:IsValid() then return end
                local sid = mainHandSID()
                if not (sid:find("Molotov") or sid == "unreadable") then return end
                local mesh
                pcall(function() mesh = anim:GetOwningComponent() end)
                if not (mesh and mesh:IsValid()) then
                    pcall(function() mesh = anim:GetOuter() end)
                end
                if not (mesh and mesh:IsValid()) then return end
                local fn = ""
                pcall(function() fn = tostring(mesh:GetSkeletalMeshAsset():GetFullName()) end)
                if fn ~= "" and not fn:find("SK_MolotovBottle", 1, true) then return end
                local owner = mesh:GetOwner()
                local ncClass = StaticFindObject("/Script/Niagara.NiagaraComponent")
                if not (ncClass and ncClass:IsValid() and owner and owner:IsValid()) then return end
                local ns, nsPath
                for _, p in ipairs(RAG_FIRE_ASSETS) do
                    ns = StaticFindObject(p)
                    if not (ns and ns:IsValid()) then ns = LoadAsset(p) end
                    if ns and ns:IsValid() then nsPath = p break end
                end
                if not (ns and ns:IsValid()) then log("ragfire: no system loadable") return end
                local idT = { Rotation = { X = 0, Y = 0, Z = 0, W = 1 },
                              Translation = { X = 0, Y = 0, Z = 0 },
                              Scale3D = { X = 1, Y = 1, Z = 1 } }
                local comp = owner:AddComponentByClass(ncClass, true, idT, false)
                if not (comp and comp:IsValid()) then log("ragfire: AddComponentByClass failed") return end
                comp:SetAsset(ns, true)
                pcall(function() comp:SetFirstPersonPrimitiveType(1) end)
                -- jnt_fuse = rag bone; root attach put the spawn volume on the grip/hand
                comp:K2_AttachToComponent(mesh, FName("jnt_fuse"), 2, 2, 0, false)
                comp:K2_SetRelativeLocation({ X = 0, Y = 0, Z = 0 }, false, {}, false)
                pcall(function() comp:SetForceSolo(true) end)   -- batched sim pauses on FP parents
                pcall(function() comp:Activate(true) end)
                -- lit smoke sprites = giant black card in unlit caves; only works on a
                -- LIVE instance (post-Activate), and handle name is uncertain -> try all
                for _, en in ipairs({ "smoke_4", "smoke", "Smoke", "smoke001" }) do
                    pcall(function() comp:SetEmitterEnable(FName(en), false) end)
                end
                fp.rag, fp.mesh, fp.animName = comp, mesh, anim:GetFullName()
                log("ragfire: lit attempt " .. attempt .. " (" .. nsPath:match("([^/]+)$") .. ")")
            end)
            if not ok then log("ragfire ERR: " .. tostring(err)) end
            if not (fp.rag and fp.rag:IsValid()) and attempt < 5 then ragFire(anim, attempt + 1) end
        end)
    end)
end

douseRagFire = function(why)
    if not fp.rag then return end
    ExecuteInGameThread(function()
        pcall(function()
            if fp.rag and fp.rag:IsValid() then
                fp.rag:Deactivate()
                fp.rag:K2_DestroyComponent(fp.rag)
            end
        end)
        fp.rag = nil
        log("ragfire: doused (" .. tostring(why) .. ")")
    end)
end

NotifyOnNewObject(FP_ANIM_PATH, function(anim)
    kickRagPhysics(anim, 1)
    if RAG_FIRE_ENABLED then ragFire(anim, 1) end
    if FP_SWAP_ENABLED then
        hookGrenadeTick()   -- main-state context; HUD widget class is loaded once hands are up
        fpSwap(anim, 1)
    elseif FLAME_ENABLED then
        fpFlame(anim)
    end
end)

-- Un-swap when the hands anim changes (lowered / thrown / weapon switched).
LoopAsync(500, function()
    if not (fp.bottle or fp.rag) then return false end
    ExecuteInGameThread(function()
        local keep = false
        pcall(function()
            local comp = fp.bottle or fp.rag
            if fp.mesh:IsValid() and comp:IsValid() then
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

-- F7: prototype-registration oracle — call the dev cheat UFunctions directly.

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

RegisterKeyBind(Key.F7, function()   -- user pref: F7 spawn (game's F7 use tolerable)
    ExecuteInGameThread(function()
        local rk = liveInstance("CustomConsoleManagerRK")
        if not rk then log("F7: no CustomConsoleManagerRK instance") return end
        local ok, err = pcall(function() rk:XCreateItemInInventoryByID("GrenadeMolotov", 0, 10, 1.0) end)
        log("F7: +10 GrenadeMolotov -> " .. (ok and "ok" or tostring(err)))
    end)
end)

local function posStep() return fineStep and 0.5 or 2 end
local function rotStep() return fineStep and 5 or 15 end

-- fold a camera-relative world move (fwd/right/up) into bone-frame xyz deltas
local function camNudge(which, sign)
    local ok, err = pcall(function()
        if not (fp.bottle and fp.bottle:IsValid() and fp.anchor and fp.anchor:IsValid()) then return end
        local kml = StaticFindObject("/Script/Engine.Default__KismetMathLibrary")
        local rot = UEHelpers.GetPlayerController():GetControlRotation()
        local v
        if which == "fwd" then v = kml:GetForwardVector(rot)
        elseif which == "right" then v = kml:GetRightVector(rot)
        else v = kml:GetUpVector(rot) end
        local sockRot = fp.anchor:GetSocketRotation(FName(fp.boneName or "None"))
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
                if fp.bottle and fp.bottle:IsValid() then
                    fp.hiddenForPivot = not fp.hiddenForPivot
                    fp.bottle:SetVisibility(not fp.hiddenForPivot, false)
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
            if fp.marker and fp.marker:IsValid() then fp.marker:K2_DestroyComponent(fp.marker) end
            if fp.handDot and fp.handDot:IsValid() then fp.handDot:K2_DestroyComponent(fp.handDot) end
            fp.marker, fp.handDot = nil, nil
            return
        end
        if fp.marker and fp.marker:IsValid() then return end
        if not (fp.bottle and fp.bottle:IsValid() and fp.anchor and fp.anchor:IsValid()) then return end
        local mesh = StaticFindObject(BOTTLE_MESH_PATH)
        local smcClass = StaticFindObject("/Script/Engine.StaticMeshComponent")
        local owner = fp.bottle:GetOwner()
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
            m:K2_AttachToComponent(fp.anchor, FName(fp.boneName or "None"), 2, 2, 0, false)
            m:SetRelativeScale3D(scale)
            return m
        end
        fp.marker = spawnDot({ X = 0.06, Y = 0.06, Z = 0.06 })      -- mini bottle = bottle pivot
        fp.handDot = spawnDot({ X = 0.5, Y = 0.5, Z = 0.04 })       -- flat disc = hand joint target
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
