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

-- live tuner in jnt_wpn_rgd5 bone frame: Ctrl+B = axis (incl. scale), Ctrl+Up/Down = step
-- s=0.36: label says 0.5L (~25cm/7cm real); 0.45 measured ~25% oversized vs hand breadth
local bottleOff = { s = 0.36, x = -8, y = -2, z = 6 }   -- user-tuned 2026-10-12
local AXES = { "x", "y", "z", "s" }
local axisIdx = 1

-- the FP anim moves the grenade's BONES into the hand; comp root stays put
local function pickGrenadeBone(mesh)
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
    log("FP sockets/bones: " .. (#names > 0 and table.concat(names, ", ") or "(none found)"))
    for _, nm in ipairs(names) do
        local l = nm:lower()
        if l:find("gre") or l:find("body") or l:find("item") or l:find("wpn") then return nm end
    end
    return names[#names]   -- leaf bone of a tiny rig = the item itself; nil -> root
end

local function applyBottleTune()
    pcall(function()
        if fp.bottle and fp.bottle:IsValid() then
            fp.bottle:SetRelativeScale3D({ X = bottleOff.s, Y = bottleOff.s, Z = bottleOff.s })
            fp.bottle:K2_SetRelativeLocation(
                { X = bottleOff.x, Y = bottleOff.y, Z = bottleOff.z }, false, {}, false)
        end
    end)
end

local function logBottleOff(prefix)
    log(string.format("%s scale %.2f offset %g %g %g (axis %s)",
        prefix, bottleOff.s, bottleOff.x, bottleOff.y, bottleOff.z, AXES[axisIdx]))
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
    fp.bottle, fp.mesh, fp.animName, fp.prevTick = nil, nil, nil, nil
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

NotifyOnNewObject(FP_ANIM_PATH, function(anim)
    -- let the game finish wiring mesh+anim before restyling it
    ExecuteWithDelay(150, function()
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
                local bone = pickGrenadeBone(mesh)
                comp:K2_AttachToComponent(mesh, FName(bone or "None"), 2, 2, 0, false)
                -- hidden skel meshes stop ticking bones by default -> bottle freezes while hands sway
                pcall(function()
                    fp.prevTick = mesh.VisibilityBasedAnimTickOption
                    mesh.VisibilityBasedAnimTickOption = 0   -- AlwaysTickPoseAndRefreshBones
                end)
                mesh:SetVisibility(false, false)   -- hide grenade; child bottle stays visible
                fp.bottle, fp.mesh, fp.animName = comp, mesh, anim:GetFullName()
                applyBottleTune()
                log("FP: bottle in hand (bone " .. tostring(bone) .. ")")
            end)
            if not ok then log("FP swap ERR: " .. tostring(err)) end
        end)
    end)
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

-- Ctrl+B: select nudge axis; Ctrl+Up/Down: move bottle ±2cm on it
RegisterKeyBind(Key.B, { ModifierKey.CONTROL }, function()
    ExecuteInGameThread(function()
        axisIdx = axisIdx % #AXES + 1
        logBottleOff("Ctrl+B axis ->")
    end)
end)

RegisterKeyBind(Key.UP_ARROW, { ModifierKey.CONTROL }, function()
    ExecuteInGameThread(function()
        local a = AXES[axisIdx]
        bottleOff[a] = bottleOff[a] + ((a == "s") and 0.02 or 2)
        applyBottleTune()
        logBottleOff("nudge +:")
    end)
end)

RegisterKeyBind(Key.DOWN_ARROW, { ModifierKey.CONTROL }, function()
    ExecuteInGameThread(function()
        local a = AXES[axisIdx]
        bottleOff[a] = bottleOff[a] - ((a == "s") and 0.02 or 2)
        applyBottleTune()
        logBottleOff("nudge -:")
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
