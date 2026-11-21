-- The burning rag on the held bottle: physics kick, rag/tip fire, and douse.
local Hands = require("hands")
local Unreal = require("unreal")

local RagFire = {}
local fp = Hands.fp

-- Rag surface fire: the player-burn system's emitters sample their attach parent's
-- skeletal mesh (NiagaraDataInterfaceSkeletalMesh), so attached to the bottle mesh
-- the fire crawls the swinging rag itself. No sound loop. Mesh-sampling clusters on
-- dense geometry (neck/plug) wherever the component sits, so the TIP flame is a
-- POSITIONAL system instead, parked on jnt_fuse_end (a real bone at the hem).
local RAG_FIRE_ASSETS = {
    "/Game/_Stalker_2/VFX/Player/NS_Character_Fire.NS_Character_Fire",
    "/Game/_Stalker_2/VFX/Anomalies/ClassicFire/Niagara/NS_ClassicFireNPCBurning.NS_ClassicFireNPCBurning",
}

-- candle first: kerosene is a campfire-scale fuel-pool system
local TIP_FIRE_ASSETS = {
    "/Game/_Stalker_2/VFX/Environment/Fire/Niagara/NS_Fire_Candle_2.NS_Fire_Candle_2",
    "/Game/_Stalker_2/VFX/Environment/Fire/Niagara/NS_Fire_Candle.NS_Fire_Candle",
    "/Game/_Stalker_2/VFX/Environment/Fire/Niagara/NS_Fire_Kerosene_2.NS_Fire_Kerosene_2",
}

-- physics owns the hands rag: kill the material droop (rag WPO default 5.0 stacks
-- on bone motion = vertex spikes). MID-wrapped slots are ours from a prior pass -
-- set directly instead of chain-wrapping.
local function zeroRagDroop(mesh)
    local zeroed = 0

    for slotIndex = 0, mesh:GetNumMaterials() - 1 do
        local material = mesh:GetMaterial(slotIndex)
        local fullName = (material and material:IsValid()) and material:GetFullName() or ""
        local mid

        if fullName:find("MaterialInstanceDynamic", 1, true) then
            mid = material
        elseif fullName:find("MolotovRag", 1, true) then
            mid = mesh:CreateDynamicMaterialInstance(slotIndex, material, FName("None"))
        end

        if mid and mid:IsValid() then
            mid:SetScalarParameterValue(FName("DroopStrength"), 0.0)
            zeroed = zeroed + 1
        end
    end

    return zeroed
end

-- In-hands rag ragdoll: the cooked PA marks jnt_fuse Simulated, but the game's
-- pooled WeaponInHandsMesh comp may never create physics state (collision off)
-- — kick it per equip. Readback-gated retry; forces PhysicsOnly collision once
-- if the first kicks land on no bodies (PA bodies have collision disabled).
function RagFire.kickPhysics(anim, attempt, generation)
    generation = generation or Hands.equipGeneration

    ExecuteInGameThreadWithDelay(attempt == 1 and 250 or 400, function()
        ExecuteInGameThread(function()
            if generation ~= Hands.equipGeneration then
                return
            end

            local isSimulating = false

            pcall(function()
                local mesh = Hands.currentRagMesh(anim)

                if not mesh then
                    return
                end

                mesh:SetAllBodiesBelowSimulatePhysics(FName("jnt_fuse"), true, true)
                mesh:SetAllBodiesBelowPhysicsBlendWeight(FName("jnt_fuse"), 1.0, false, true)

                pcall(function()
                    isSimulating = mesh:IsSimulatingPhysics(FName("jnt_fuse"))
                end)

                local zeroed = zeroRagDroop(mesh)
                Unreal.log(
                    "rag physics: kick attempt "
                        .. attempt
                        .. " sid="
                        .. Hands.MOLOTOV_SID
                        .. " simulating="
                        .. tostring(isSimulating)
                        .. " droop0="
                        .. zeroed
                )

                if not isSimulating and attempt >= 3 then
                    -- no physics state at all: PhysicsOnly wakes it (2 = ECollisionEnabled)
                    pcall(function()
                        mesh:SetCollisionEnabled(2)
                    end)
                end
            end)

            if not isSimulating and attempt < 4 then
                RagFire.kickPhysics(anim, attempt + 1, generation)
            end
        end)
    end)
end

local function lightAt(owner, ncClass, mesh, bone, rotationRule, system)
    local component = owner:AddComponentByClass(ncClass, true, Unreal.identityTransform(), false)

    if not (component and component:IsValid()) then
        return nil
    end

    component:SetAsset(system, true)

    pcall(function()
        component:SetFirstPersonPrimitiveType(1)
    end)

    -- chain links' bone frames roll with the hang line and the system's authored
    -- emitter offsets rotate with them (fire floats off the cloth) — rotationRule
    -- 1 = KeepWorld pins the frame upright
    component:K2_AttachToComponent(mesh, FName(bone), 2, rotationRule or 2, 0, false)
    component:K2_SetRelativeLocation({ X = 0, Y = 0, Z = 0 }, false, {}, false)

    pcall(function()
        component:SetForceSolo(true) -- batched sim pauses on FP parents
    end)

    pcall(function()
        component:Activate(true)
    end)

    -- smoke off on the HELD fire only: it is a lit translucent sprite spawning at
    -- the rag bone, so sprinting pushes the camera through it and blanks the view
    -- for a frame. Must follow Activate — SetEmitterEnable before the system is
    -- live is a silent no-op.
    pcall(function()
        component:SetEmitterEnable(FName("smoke"), false)
    end)

    return component
end

local function lightNow(anim, attempt)
    if Unreal.isAlive(fp.rag) then
        return
    end

    local mesh = Hands.currentRagMesh(anim)

    if not mesh then
        return
    end

    local owner = mesh:GetOwner()
    local ncClass = StaticFindObject("/Script/Niagara.NiagaraComponent")

    if not (ncClass and ncClass:IsValid() and owner and owner:IsValid()) then
        return
    end

    local system, systemPath = Unreal.loadFirst(RAG_FIRE_ASSETS)

    if not (system and system:IsValid()) then
        Unreal.log("ragfire: no system loadable")
        return
    end

    local tipSystem, tipPath = Unreal.loadFirst(TIP_FIRE_ASSETS)

    -- jnt_fuse = mouth anchor: the mesh-sampling blaze. Tip = positional flame on
    -- the hem-end bone; follows the swinging tip exactly.
    local component = lightAt(owner, ncClass, mesh, "jnt_fuse", nil, system)

    if not component then
        Unreal.log("ragfire: AddComponentByClass failed")
        return
    end

    local lower = {}

    if tipSystem then
        local tipComponent = lightAt(owner, ncClass, mesh, "jnt_fuse_end", 1, tipSystem)

        if tipComponent then
            lower[#lower + 1] = tipComponent
        end
    end

    fp.rag, fp.mesh, fp.animName = component, mesh, anim:GetFullName()
    fp.ragLower = lower -- wrappers; douse resolves via Unreal.isAlive
    Hands.mp.cur = {}
    Unreal.log(
        string.format(
            "ragfire: lit attempt %d (%s + tip %s)",
            attempt,
            systemPath:match("([^/]+)$"),
            tipPath and tipPath:match("([^/]+)$") or "none"
        )
    )
end

function RagFire.light(anim, attempt, generation)
    generation = generation or Hands.equipGeneration

    ExecuteInGameThreadWithDelay(attempt == 1 and 400 or 500, function()
        ExecuteInGameThread(function()
            if generation ~= Hands.equipGeneration then
                return
            end

            local ok, errorMessage = pcall(lightNow, anim, attempt)

            if not ok then
                Unreal.log("ragfire ERR: " .. tostring(errorMessage))
            end

            if not Unreal.isAlive(fp.rag) and attempt < 5 then
                RagFire.light(anim, attempt + 1, generation)
            end
        end)
    end)
end

function RagFire.douse(reason)
    Hands.invalidateEquip()

    if not fp.rag then
        return
    end

    local rag, lower = fp.rag, fp.ragLower
    fp.rag, fp.ragLower = nil, nil

    ExecuteInGameThread(function()
        pcall(function()
            if Unreal.isAlive(rag) then
                rag:Deactivate()
                rag:K2_DestroyComponent(rag)
            end
        end)

        for _, component in ipairs(lower or {}) do
            pcall(function()
                if Unreal.isAlive(component) then
                    component:Deactivate()
                    component:K2_DestroyComponent(component)
                end
            end)
        end

        Unreal.log("ragfire: doused (" .. tostring(reason) .. ")")
    end)
end

return RagFire
