-- Host helpers shared by every MolotovFire module: logging and defensive UObject
-- access. Wrappers can outlive their objects, so callers re-check liveness right
-- before use instead of trusting a cached result.
local Unreal = {}

Unreal.CPP_MEDIATOR_PATH = "/Script/Stalker2.Default__CppMediator"

function Unreal.log(message)
    print("[MolotovFire] " .. message .. "\n")
end

function Unreal.address(object)
    local ok, address = pcall(function()
        return object:GetAddress()
    end)

    if ok and type(address) == "number" then
        return address
    end

    return nil
end

function Unreal.isAlive(object)
    local ok, isValid = pcall(function()
        return object and object:IsValid()
    end)

    return ok and isValid == true
end

function Unreal.isSameObject(first, second)
    local ok, isSame = pcall(function()
        return first:GetAddress() == second:GetAddress()
    end)

    if ok then
        return isSame
    end

    local okByName, isSameName = pcall(function()
        return first:GetFullName() == second:GetFullName()
    end)

    return okByName and isSameName
end

-- Finds a live (non-CDO) instance of a native class; the console managers are
-- only usable this way.
function Unreal.liveInstance(className)
    local instances = FindAllOf(className)

    if instances then
        for _, instance in ipairs(instances) do
            -- skip the CDO: calling spawn helpers on it null-derefs (no world)
            if instance:IsValid() and not instance:GetFullName():find("Default__") then
                return instance
            end
        end
    end

    return nil
end

-- First asset in priority order that is already loaded or loads now.
function Unreal.loadFirst(paths)
    for _, path in ipairs(paths) do
        local asset = StaticFindObject(path)

        if not (asset and asset:IsValid()) then
            asset = LoadAsset(path)
        end

        if asset and asset:IsValid() then
            return asset, path
        end
    end
end

-- Fresh table per call: AddComponentByClass receives it by value.
function Unreal.identityTransform()
    return {
        Rotation = { X = 0, Y = 0, Z = 0, W = 1 },
        Translation = { X = 0, Y = 0, Z = 0 },
        Scale3D = { X = 1, Y = 1, Z = 1 },
    }
end

return Unreal
