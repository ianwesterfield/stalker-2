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

NotifyOnNewObject("/Game/GameLite/Blueprints/Grenades/BP_grenade.BP_Grenade_C", function(grenade)
    tracked[#tracked + 1] = { actor = grenade, x = 0, y = 0, z = 0, alive = true, seen = 0 }
    trackedCount = trackedCount + 1
    log("grenade spawned (equipped)")
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
                local mesh = StaticFindObject(BOTTLE_MESH_PATH) or LoadAsset(BOTTLE_MESH_PATH)
                if not (mesh and mesh:IsValid()) then log("bottleize: mesh load failed") return end
                local smc = grenade.StaticMeshComponent
                if smc and smc:IsValid() then
                    smc:SetStaticMesh(mesh)
                    log("bottleize: swapped")
                end
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
                    -- fuse timer beats GC: actors linger ~1min after the boom
                    if t.armed and os.clock() >= t.boomAt then
                        t.alive = false
                        trackedCount = trackedCount - 1
                        log(string.format("BOOM (fuse) at %.0f %.0f %.0f", t.x, t.y, t.z))
                        local okF, errF = pcall(spawnGroundFire, t.x, t.y, t.z, t.hx, t.hy)
                        if not okF then log("FIRE handler error: " .. tostring(errF)) end
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
                                    t.boomAt = os.clock() + 1.25   -- TimeToExplode=1.2f from release
                                    log("thrown - fuse lit")
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
                        if t.armed then
                            -- died mid-fuse = engine detonated it; last position is ground zero
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
-- RECONSTRUCTION: deltas are now zero — the live grenade-match base IS the grip
-- point (bounds center pinned on jnt_wpn_rgd5); rx-90 = the approved orientation,
-- s=0.5 reads hand-proportional. Tune from here with HOME and bake the result.
local bottleOff = { s = 0.5, x = 0, y = 0, z = 0, rx = -90, ry = 0, rz = 0 }
local tuneMode, fineStep = false, false
local showPivotMarker   -- fwd-declared; defined with the tuner keys below

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

local function applyBottleTune()
    pcall(function()
        if fp.bottle and fp.bottle:IsValid() then
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
local function sampleGrenadeBase(tag)
    local ok, err = pcall(function()
        if not (fp.bottle and fp.bottle:IsValid() and fp.mesh and fp.mesh:IsValid()) then return end
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
local function trackTick()
    if not (fp.bottle and fp.bottle:IsValid() and fp.mesh and fp.mesh:IsValid()
            and fp.anchor and fp.anchor:IsValid() and fp.anchor ~= fp.mesh) then return end
    local g = fp.mesh:GetSocketLocation(FName("jnt_wpn_rgd5"))
    local function dist(bone)
        local h = fp.anchor:GetSocketLocation(FName(bone))
        local dx, dy, dz = g.X - h.X, g.Y - h.Y, g.Z - h.Z
        return math.sqrt(dx * dx + dy * dy + dz * dz)
    end
    local dR = dist(fp.boneName or "jnt_r_hand")
    local dL = dist("jnt_l_hand")
    if math.min(dR, dL) > 35 then return end   -- locomotion desync rides the legs - hold last good base
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
                        end
                    end)
                end)
            end)
            if not ok then log("FP swap ERR: " .. tostring(err)) end
        end)
    end)
end

NotifyOnNewObject(FP_ANIM_PATH, function(anim)
    hookGrenadeTick()   -- main-state context; HUD widget class is loaded once hands are up
    fpSwap(anim, 1)
end)

-- Un-swap when the hands anim changes (lowered / thrown / weapon switched).
LoopAsync(500, function()
    if not fp.bottle then return false end
    ExecuteInGameThread(function()
        local keep = false
        pcall(function()
            if fp.mesh:IsValid() and fp.bottle:IsValid() then
                local cur = fp.mesh.AnimScriptInstance
                keep = cur and cur:IsValid() and cur:GetFullName() == fp.animName
            end
        end)
        if fp.bottle and not keep then
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

RegisterKeyBind(Key.F7, function()
    ExecuteInGameThread(function()
        log("F7 pressed")
        local build = liveInstance("CustomConsoleManagerBuild")
        log("CCM Build instance: " .. tostring(build ~= nil))
        if build then
            for _, sid in ipairs({ "Vodka", "GrenadeMolotov" }) do
                local ok, err = pcall(function() build:XSpawnItemNearPlayerBySID(sid) end)
                log("XSpawnItemNearPlayerBySID " .. sid .. " -> " .. (ok and "called" or tostring(err)))
            end
        end
        local rk = liveInstance("CustomConsoleManagerRK")
        log("CCM RK instance: " .. tostring(rk ~= nil))
        if rk then
            local ok, err = pcall(function() rk:XCreateItemInInventoryByID("GrenadeMolotov", 0, 3, 1.0) end)
            log("XCreateItemInInventoryByID GrenadeMolotov -> " .. (ok and "called" or tostring(err)))
        end
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
        and "ON - movement locked | WASD move, PgUp/PgDn depth, arrows pitch/yaw, ,/. roll, -/= scale, V peek pivot, End fine"
        or "OFF - movement restored"))
    if on then logBottleOff("state:") end
end

RegisterKeyBind(Key.HOME, function()
    ExecuteInGameThread(function() setTuneMode(not tuneMode) end)
end)

RegisterKeyBind(Key.END, function()
    ExecuteInGameThread(function()
        fineStep = not fineStep
        log("tune steps: " .. (fineStep and "FINE 0.5cm/5deg" or "coarse 2cm/15deg"))
    end)
end)

local function tuneBind(key, fn)
    RegisterKeyBind(key, function()
        if not tuneMode then return end
        ExecuteInGameThread(fn)
    end)
end

tuneBind(Key.W, function() camNudge("up", 1) end)
tuneBind(Key.S, function() camNudge("up", -1) end)
tuneBind(Key.A, function() camNudge("right", -1) end)
tuneBind(Key.D, function() camNudge("right", 1) end)
tuneBind(Key.PAGE_UP, function() camNudge("fwd", -1) end)   -- toward camera
tuneBind(Key.PAGE_DOWN, function() camNudge("fwd", 1) end)
tuneBind(Key.UP_ARROW, function() rotNudge("ry", 1) end)
tuneBind(Key.DOWN_ARROW, function() rotNudge("ry", -1) end)
tuneBind(Key.LEFT_ARROW, function() rotNudge("rz", -1) end)
tuneBind(Key.RIGHT_ARROW, function() rotNudge("rz", 1) end)
tuneBind(Key.OEM_COMMA, function() rotNudge("rx", -1) end)
tuneBind(Key.OEM_PERIOD, function() rotNudge("rx", 1) end)
tuneBind(Key.OEM_MINUS, function()
    bottleOff.s = math.max(0.02, bottleOff.s - (fineStep and 0.02 or 0.1))
    applyBottleTune()
    logBottleOff("scale-:")
end)
tuneBind(Key.OEM_PLUS, function()
    bottleOff.s = bottleOff.s + (fineStep and 0.02 or 0.1)
    applyBottleTune()
    logBottleOff("scale+:")
end)
tuneBind(Key.V, function()
    pcall(function()
        if fp.bottle and fp.bottle:IsValid() then
            fp.hiddenForPivot = not fp.hiddenForPivot
            fp.bottle:SetVisibility(not fp.hiddenForPivot, false)
            log("bottle " .. (fp.hiddenForPivot and "hidden - pivot dot + hand disc exposed" or "shown"))
        end
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
