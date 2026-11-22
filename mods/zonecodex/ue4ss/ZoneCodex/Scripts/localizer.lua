-- Expands the generated {sid_...} templates into text in the player's language. Pure: the
-- caller passes the lookup, so it is safe anywhere and the game is only asked on its thread.
local Localizer = {}

local TOKEN_PATTERN = "{(sid_[%w_]+)}"

-- Mirrors build_codex.clean_text: note prefixes, input glyphs, rich-text tags, CRLF, blank runs.
function Localizer.clean(text)
    text = text:gsub("^%$[A-Z0-9]+", "")
    text = text:gsub("<input>", "[key]")
    text = text:gsub("<[^>]+>", "")
    text = text:gsub("\r\n", "\n")
    text = text:gsub("\n\n\n+", "\n\n")
    return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

---@param lookup fun(key: string): string|nil The key's text in the player's language, or nil.
---@param fallbacks table<string, string> English text per key, for keys the lookup lacks.
---@param stats { fallback: integer, localized: integer }|nil Counts tokens by text source.
function Localizer.expand(template, lookup, fallbacks, stats)
    local expanded = template:gsub(TOKEN_PATTERN, function(key)
        local text = lookup(key)

        if type(text) == "string" and text ~= "" then
            if stats then
                stats.localized = stats.localized + 1
            end

            return Localizer.clean(text)
        end

        if stats then
            stats.fallback = stats.fallback + 1
        end

        return fallbacks[key] or ""
    end)

    -- An empty passage would leave a stray paragraph break in multi-key lore.
    return (expanded:gsub("\n\n\n+", "\n\n"):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function expandList(values, expand)
    local expanded = {}

    for index, value in ipairs(values) do
        expanded[index] = expand(value)
    end

    return expanded
end

---@param templateTabs ZoneCodexTab[] Tabs as loaded, with {sid_...} templates in their text.
---@return ZoneCodexTab[] tabs Fresh tabs with expanded text, entries re-sorted by localized name.
---@return { fallback: integer, localized: integer } stats
function Localizer.resolveTabs(templateTabs, lookup, fallbacks)
    local stats = { fallback = 0, localized = 0 }
    local cache = {}

    local function expand(template)
        if cache[template] == nil then
            cache[template] = Localizer.expand(template, lookup, fallbacks, stats)
        end

        return cache[template]
    end

    local tabs = {}

    for tabIndex, templateTab in ipairs(templateTabs) do
        local entries = {}

        for entryIndex, templateEntry in ipairs(templateTab.entries) do
            local facts = {}

            for factIndex, fact in ipairs(templateEntry.facts) do
                facts[factIndex] = expandList(fact, expand)
            end

            entries[entryIndex] = {
                bullets = expandList(templateEntry.bullets, expand),
                description = expand(templateEntry.description),
                detailIcon = templateEntry.detailIcon,
                facts = facts,
                icon = templateEntry.icon,
                id = templateEntry.id,
                image = templateEntry.image,
                name = expand(templateEntry.name),
                sids = templateEntry.sids,
            }
        end

        table.sort(entries, function(first, second)
            local firstName, secondName = first.name:lower(), second.name:lower()

            if firstName ~= secondName then
                return firstName < secondName
            end

            return first.id < second.id
        end)

        tabs[tabIndex] = {
            bulletsTitle = expand(templateTab.bulletsTitle),
            descriptionFirst = templateTab.descriptionFirst,
            entries = entries,
            id = templateTab.id,
            maskIcons = templateTab.maskIcons,
            title = expand(templateTab.title),
            tracksInventory = templateTab.tracksInventory,
        }
    end

    return tabs, stats
end

return Localizer
