-- First-person hands: the equip-scoped state shared by every in-hands feature,
-- plus the helpers that resolve the live molotov rig.
local Unreal = require("unreal")

local Hands = {}

Hands.MOLOTOV_SID = "GrenadeMolotov"

-- One instance per UE4SS Lua state. `fp` and `mp` are never reassigned, so modules
-- may alias them; Hands.restore wipes `fp` whenever the hands change.
Hands.fp = {} -- hands mesh + anim full-name + rag fire components while lit
Hands.mp = { cur = {} } -- pin-pull montage latch per rig ("wpn"/"body")

-- Bumped on every equip/douse/restore; delayed retries carry the value they were
-- scheduled with and give up once it changes.
Hands.equipGeneration = 0

function Hands.invalidateEquip()
    Hands.equipGeneration = Hands.equipGeneration + 1
    Hands.mp.cur = {}
end

local function destroyComponent(component)
    pcall(function()
        if Unreal.isAlive(component) then
            component:K2_DestroyComponent(component)
        end
    end)
end

function Hands.restore()
    local fp = Hands.fp
    Hands.invalidateEquip()

    pcall(function()
        if Unreal.isAlive(fp.mesh) then
            fp.mesh:SetVisibility(true, false)
        end
    end)

    destroyComponent(fp.rag)

    for _, component in ipairs(fp.ragLower or {}) do
        destroyComponent(component)
    end

    -- every field is per-equip: wipe the whole stash
    for field in pairs(fp) do
        fp[field] = nil
    end
end

function Hands.mainHandSID()
    local sid = "unreadable"

    pcall(function()
        local mediator = StaticFindObject(Unreal.CPP_MEDIATOR_PATH)

        if mediator and mediator:IsValid() then
            local data = mediator:GetPlayerItemInHandsData()
            local value = data.MainHandItemPrototypeID
            local text = tostring(value and value.ToString and value:ToString() or value)

            if text ~= "" and text ~= "nil" then
                sid = text
            end
        end
    end)

    return sid
end

-- The pooled hands mesh of the molotov, only while `anim` is still its current
-- AnimBP instance (the pool hands the mesh to other weapons).
function Hands.currentRagMesh(anim)
    if Hands.mainHandSID() ~= Hands.MOLOTOV_SID or not Unreal.isAlive(anim) then
        return nil
    end

    local mesh

    pcall(function()
        mesh = anim:GetOwningComponent()
    end)

    -- the AnimBP instance's outer IS the WeaponInHandsMesh comp
    if not Unreal.isAlive(mesh) then
        pcall(function()
            mesh = anim:GetOuter()
        end)
    end

    if not Unreal.isAlive(mesh) then
        return nil
    end

    local current = mesh.AnimScriptInstance

    if not Unreal.isAlive(current) or not Unreal.isSameObject(current, anim) then
        return nil
    end

    local assetName = ""

    pcall(function()
        assetName = mesh:GetSkeletalMeshAsset():GetFullName()
    end)

    if assetName ~= "" and not assetName:find("SK_MolotovBottle", 1, true) then
        return nil
    end

    return mesh
end

return Hands
