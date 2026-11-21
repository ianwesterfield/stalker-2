local Unreal = require("unreal")

---@class ZoneAtlasConfig
---@field GameDefaultName string
---@field HintLabel string
---@field Key string
---@field OnlyWhenMapOpen boolean
---@field ShowHint boolean
---@field ToastSeconds number
---@field UseMCM boolean

---@class ZoneAtlasEntry
---@field name string
---@field path? string Absent for the game's own texture.

local Catalog = {
    ---@type ZoneAtlasConfig
    config = {},
    
    ---@type ZoneAtlasEntry[]
    entries = {},
    
    ownedPaths = {},
    selected = 1,
}

local DEFAULTS = {
    GameDefaultName = "Game default",
    HintLabel = "Map style",
    Key = "F6",
    OnlyWhenMapOpen = true,
    ShowHint = true,
    ToastSeconds = 2.5,
    UseMCM = true,
}

local stateFile

local function loadTable(path)
    local chunk, errorMessage = loadfile(path)

    if not chunk then
        return nil, errorMessage
    end

    local ok, value = pcall(chunk)

    if not ok or type(value) ~= "table" then
        return nil, tostring(value)
    end

    return value
end

function Catalog.load(modDirectory)
    stateFile = modDirectory .. "\\selected.txt"
    local config, configError = loadTable(modDirectory .. "\\Scripts\\config.lua")

    if not config then
        Unreal.log("config.lua not loaded (" .. tostring(configError) .. "); using defaults")
    end

    Catalog.config = config or {}

    for key, defaultValue in pairs(DEFAULTS) do
        local value = Catalog.config[key]

        if value == nil then
            Catalog.config[key] = defaultValue
        elseif type(value) ~= type(defaultValue) or (key == "ToastSeconds" and not (value >= 0)) then
            Unreal.log("invalid config value for " .. key .. "; using its default")
            Catalog.config[key] = defaultValue
        end
    end

    local entries, hasVanilla, ownedPaths = {}, false, {}
    local manifest, manifestError = loadTable(modDirectory .. "\\Scripts\\atlas_manifest.lua")

    if not manifest then
        Unreal.log("atlas_manifest.lua missing (" .. tostring(manifestError) .. "); run build + deploy-zoneatlas.ps1")
    end

    for index, entry in ipairs(manifest or {}) do
        if
            type(entry) == "table"
            and type(entry.name) == "string"
            and entry.name ~= ""
            and type(entry.texture) == "string"
            and entry.texture ~= ""
        then
            entries[#entries + 1] = { name = entry.name, path = entry.texture }
            ownedPaths[entry.texture] = true
            hasVanilla = hasVanilla or entry.vanilla == true
        else
            Unreal.log("invalid atlas manifest entry at index " .. index .. "; skipping it")
        end
    end

    if not hasVanilla then
        table.insert(entries, 1, { name = Catalog.config.GameDefaultName })
    end

    Catalog.entries, Catalog.ownedPaths, Catalog.selected = entries, ownedPaths, 1
    local stateHandle = io.open(stateFile, "r")
    local savedName = stateHandle and stateHandle:read("*l")

    if stateHandle then
        stateHandle:close()
    end

    for index, entry in ipairs(entries) do
        if entry.name == savedName then
            Catalog.selected = index
            break
        end
    end

    return Catalog
end

function Catalog.inCycle(entry)
    return not Catalog.enabled or Catalog.enabled[entry.name] == true
end

function Catalog.save()
    local handle, errorMessage = io.open(stateFile, "w")

    if not handle then
        error("cannot save map selection: " .. tostring(errorMessage))
    end

    local written, writeError = handle:write(Catalog.entries[Catalog.selected].name)
    local closed, closeError = handle:close()
    
    assert(written and closed, "cannot save map selection: " .. tostring(writeError or closeError))
end

return Catalog
