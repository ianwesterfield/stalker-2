local Unreal = require("unreal")

---@class ZoneCodexConfig
---@field ArchiveDetailColumns number
---@field ArchiveDetailLines number
---@field ArchiveRows number
---@field DetailColumns number
---@field Key string
---@field LineHeight number
---@field Modifier string UE4SS ModifierKey name, or "" for none.
---@field RefreshSeconds number
---@field RequirePda boolean
---@field UseArchiveTab boolean
---@field VisibleRows number

---@class ZoneCodexEntry
---@field bullets string[]
---@field description string
---@field detailIcon string Header icon when it differs from the list icon (a mutant's trophy part), or "".
---@field facts string[][]
---@field icon string Texture2D object path, or "" when the game has no icon for it.
---@field id string
---@field image string Large picture beside the details (a mutant's render), or "".
---@field name string
---@field sids string[] Item prototype SIDs whose carried quantities this entry sums.

---@class ZoneCodexTab
---@field bulletsTitle string
---@field descriptionFirst boolean Lore-style tabs lead with the description, facts after it.
---@field entries ZoneCodexEntry[]
---@field id string
---@field maskIcons boolean Icons are white masks (faction badges) drawn tinted.
---@field title string
---@field tracksInventory boolean

local Catalog = {}

local DEFAULTS = {
    ArchiveDetailColumns = 72,
    ArchiveDetailLines = 18,
    ArchiveRows = 10,
    DetailColumns = 64,
    Key = "E",
    LineHeight = 26,
    Modifier = "CONTROL",
    RefreshSeconds = 2,
    RequirePda = true,
    Sounds = true,
    UseArchiveTab = true,
    VisibleRows = 16,
}

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

local function isStringList(value)
    if type(value) ~= "table" then
        return false
    end

    for _, item in ipairs(value) do
        if type(item) ~= "string" then
            return false
        end
    end

    return true
end

local function isValidEntry(entry)
    if type(entry) ~= "table" or type(entry.id) ~= "string" or type(entry.name) ~= "string" or entry.name == "" then
        return false
    end

    if type(entry.description) ~= "string" or not isStringList(entry.sids) or not isStringList(entry.bullets) then
        return false
    end

    if type(entry.facts) ~= "table" then
        return false
    end

    for _, fact in ipairs(entry.facts) do
        if not isStringList(fact) or #fact ~= 2 then
            return false
        end
    end

    return true
end

local function loadConfig(path)
    local config, configError = loadTable(path)

    if not config then
        Unreal.log("config.lua not loaded (" .. tostring(configError) .. "); using defaults")
        config = {}
    end

    for key, defaultValue in pairs(DEFAULTS) do
        local value = config[key]

        if value == nil then
            config[key] = defaultValue
        elseif type(value) ~= type(defaultValue) or (type(value) == "number" and not (value > 0)) then
            Unreal.log("invalid config value for " .. key .. "; using its default")
            config[key] = defaultValue
        end
    end

    config.ArchiveDetailColumns = math.max(24, math.floor(config.ArchiveDetailColumns))
    config.ArchiveDetailLines = math.max(3, math.floor(config.ArchiveDetailLines))
    config.ArchiveRows = math.max(3, math.floor(config.ArchiveRows))
    config.DetailColumns = math.max(24, math.floor(config.DetailColumns))
    config.LineHeight = math.max(12, math.floor(config.LineHeight))
    config.Modifier = config.Modifier:upper()
    config.VisibleRows = math.max(3, math.floor(config.VisibleRows))
    return config
end

local function loadFallbacks(value)
    local fallbacks = {}

    if type(value) ~= "table" then
        Unreal.log("codex_data.lua has no fallbacks; untranslated text shows blank (rebuild the data)")
        return fallbacks
    end

    for key, text in pairs(value) do
        if type(key) == "string" and type(text) == "string" then
            fallbacks[key] = text
        end
    end

    return fallbacks
end

local function loadTabs(path)
    local data, dataError = loadTable(path)

    if not data then
        Unreal.log("codex_data.lua missing (" .. tostring(dataError) .. "); run build + deploy-zonecodex.ps1")
        return {}, {}
    end

    if type(data.tabs) ~= "table" then
        Unreal.log("codex_data.lua is from an older ZoneCodex; run build + deploy-zonecodex.ps1")
        return {}, {}
    end

    local tabs = {}

    for tabIndex, tab in ipairs(data.tabs) do
        if type(tab) == "table" and type(tab.title) == "string" and type(tab.entries) == "table" then
            local entries = {}

            for entryIndex, entry in ipairs(tab.entries) do
                if isValidEntry(entry) then
                    -- Pictures are optional; older generated data has none.
                    for _, field in ipairs({ "detailIcon", "icon", "image" }) do
                        entry[field] = type(entry[field]) == "string" and entry[field] or ""
                    end

                    entries[#entries + 1] = entry
                else
                    Unreal.log(string.format("invalid codex entry %s[%d]; skipping it", tab.title, entryIndex))
                end
            end

            if #entries > 0 then
                tabs[#tabs + 1] = {
                    bulletsTitle = type(tab.bulletsTitle) == "string" and tab.bulletsTitle or "",
                    descriptionFirst = tab.descriptionFirst == true,
                    entries = entries,
                    id = tostring(tab.id),
                    maskIcons = tab.maskIcons == true,
                    title = tab.title,
                    tracksInventory = tab.tracksInventory == true,
                }
            end
        else
            Unreal.log("invalid codex tab at index " .. tabIndex .. "; skipping it")
        end
    end

    return tabs, loadFallbacks(data.fallbacks)
end

---@return ZoneCodexConfig config
---@return ZoneCodexTab[] tabs Text fields are {sid_...} templates; see localizer.lua.
---@return table<string, string> fallbacks English text per localization key.
function Catalog.load(modDirectory)
    local config = loadConfig(modDirectory .. "\\Scripts\\config.lua")
    local tabs, fallbacks = loadTabs(modDirectory .. "\\Scripts\\codex_data.lua")

    return config, tabs, fallbacks
end

return Catalog
