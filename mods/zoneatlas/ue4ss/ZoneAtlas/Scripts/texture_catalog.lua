local Catalog = require("catalog")
local UEHelpers = require("UEHelpers")
local Unreal = require("unreal")

local Textures = {}
local brokenPaths, textureCache, virtualTextureChecks = {}, {}, {}

local function newName(name)
    if type(UEHelpers.FindOrAddFName) == "function" then
        return UEHelpers.FindOrAddFName(name)
    end

    return EFindName and EFindName.FNAME_Add and FName(name, EFindName.FNAME_Add) or FName(name)
end

local function loadByPath(path)
    local packageName, assetName = path:match("^(.-)%.([^%./]+)$")
    local registry = StaticFindObject("/Script/AssetRegistry.Default__AssetRegistryHelpers")

    if packageName and Unreal.isValid(registry) then
        return registry:GetAsset({ PackageName = newName(packageName), AssetName = newName(assetName) })
    end
end

local function loadTexture(path)
    local texture = textureCache[path]

    -- Lua references do not keep UObject assets alive between swaps.
    if Unreal.isValid(texture) and Unreal.objectPath(texture) == path then
        return texture
    end

    textureCache[path] = nil
    texture = StaticFindObject(path)

    if Unreal.isValid(texture) then
        textureCache[path] = texture
        return texture
    end

    for _, loader in ipairs({ { "GetAsset", loadByPath }, { "LoadAsset", LoadAsset } }) do
        if type(loader[2]) == "function" then
            local ok, result = pcall(loader[2], path)

            if ok and Unreal.isValid(result) then
                textureCache[path] = result
                Unreal.log("loaded " .. path .. " via " .. loader[1])
                
                return result
            elseif not ok then
                Unreal.log(loader[1] .. "(" .. path .. ") failed: " .. tostring(result))
            end
        end
    end
end

local function isVirtual(texture)
    local ok, virtual = pcall(function()
        return texture.VirtualTextureStreaming
    end)

    if ok and type(virtual) == "boolean" then
        return virtual
    end
end

function Textures.usable(entry)
    if not entry.path then
        return Catalog.gameDefaultPath ~= nil
    end

    if brokenPaths[entry.path] then
        return false
    end

    local checkKey = Catalog.gameDefaultPath and (entry.path .. "|" .. Catalog.gameDefaultPath)

    if checkKey and virtualTextureChecks[checkKey] then
        return true
    end

    local texture = loadTexture(entry.path)

    if not texture then
        brokenPaths[entry.path] = true
        Unreal.log("can't load '" .. entry.name .. "' (" .. entry.path .. ") -- is ZoneAtlas_P deployed? skipping it")
        return false
    end

    -- Cache the compatibility result, not a reference to the ~200 MB default texture.
    local baseTexture = Catalog.gameDefaultPath and loadTexture(Catalog.gameDefaultPath)
    local virtual, baseVirtual = isVirtual(texture), baseTexture and isVirtual(baseTexture)

    if virtual ~= nil and baseVirtual ~= nil and virtual ~= baseVirtual then
        brokenPaths[entry.path] = true
        Unreal.log(
            string.format(
                "'%s' virtual-texture=%s but the PDA expects %s -- skipping it",
                entry.name,
                tostring(virtual),
                tostring(baseVirtual)
            )
        )
        
        return false
    end

    if checkKey and baseTexture then
        virtualTextureChecks[checkKey] = true
    end

    return true
end

function Textures.desired(entry)
    if Textures.usable(entry) then
        local path = entry.path or Catalog.gameDefaultPath
        return loadTexture(path), path
    end
end

return Textures
