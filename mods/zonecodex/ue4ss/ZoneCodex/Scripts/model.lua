-- Pure master/detail state and text layout. No Unreal access, so it is safe anywhere.
local Model = {}

local ELLIPSIS = "..."
local NAME_COLUMNS = 30
local ROW_NAME_COLUMNS = 36
local ROW_SUBTITLE_COLUMNS = 52

---@class ZoneCodexView
---@field detailOffset integer First visible detail line (0-based).
---@field offsets integer[] First visible list row per tab (0-based).
---@field selections integer[] Selected entry per tab.
---@field tabIndex integer

---@alias ZoneCodexCounts table<string, integer> Carried quantity per entry id; nil table = unknown.

local function clamp(value, minimum, maximum)
    return math.max(minimum, math.min(maximum, value))
end

local function length(text)
    return utf8.len(text) or #text
end

local function prefix(text, characters)
    local cutoff = utf8.offset(text, characters + 1)

    if cutoff then
        return text:sub(1, cutoff - 1)
    end

    return text
end

---@param tabCount integer
---@return ZoneCodexView
function Model.new(tabCount)
    local view = { detailOffset = 0, offsets = {}, selections = {}, tabIndex = 1 }

    for tabIndex = 1, tabCount do
        view.offsets[tabIndex] = 0
        view.selections[tabIndex] = 1
    end

    return view
end

---@param tabs ZoneCodexTab[]
---@param view ZoneCodexView
function Model.selectedEntry(tabs, view)
    return tabs[view.tabIndex].entries[view.selections[view.tabIndex]]
end

function Model.switchTab(view, tabs, direction)
    view.tabIndex = (view.tabIndex - 1 + direction) % #tabs + 1
    view.detailOffset = 0
end

function Model.selectTab(view, tabs, tabIndex)
    if tabs[tabIndex] and tabIndex ~= view.tabIndex then
        view.tabIndex = tabIndex
        view.detailOffset = 0
    end
end

function Model.move(view, tabs, delta, visibleRows)
    local entryCount = #tabs[view.tabIndex].entries
    local selected = clamp(view.selections[view.tabIndex] + delta, 1, entryCount)
    local offset = view.offsets[view.tabIndex]

    if selected <= offset then
        offset = selected - 1
    elseif selected > offset + visibleRows then
        offset = selected - visibleRows
    end

    view.selections[view.tabIndex] = selected
    view.offsets[view.tabIndex] = offset
    view.detailOffset = 0
end

-- A click on visible row `row` selects the entry shown there; empty rows are ignored.
function Model.selectRow(view, tabs, row, visibleRows)
    local entryIndex = view.offsets[view.tabIndex] + row

    if tabs[view.tabIndex].entries[entryIndex] then
        Model.move(view, tabs, entryIndex - view.selections[view.tabIndex], visibleRows)
    end
end

function Model.scrollDetail(view, delta, lineCount, visibleRows)
    view.detailOffset = clamp(view.detailOffset + delta, 0, math.max(0, lineCount - visibleRows))
end

-- Wheel scrolling moves the visible window, like a vanilla list; the selection stays put.
function Model.scrollList(view, tabs, delta, visibleRows)
    local entryCount = #tabs[view.tabIndex].entries
    local offset = view.offsets[view.tabIndex] + delta

    view.offsets[view.tabIndex] = clamp(offset, 0, math.max(0, entryCount - visibleRows))
end

function Model.truncate(text, columns)
    if length(text) <= columns then
        return text
    end

    return prefix(text, columns - #ELLIPSIS) .. ELLIPSIS
end

-- Greedy word wrap by character count; words longer than a line are split.
function Model.wrap(text, columns)
    local lines = {}

    for paragraph in (text .. "\n"):gmatch("(.-)\n") do
        local line = ""

        for word in paragraph:gmatch("%S+") do
            while length(word) > columns do
                if line ~= "" then
                    lines[#lines + 1] = line
                    line = ""
                end

                lines[#lines + 1] = prefix(word, columns)
                word = word:sub(#prefix(word, columns) + 1)
            end

            if line == "" then
                line = word
            elseif length(line) + 1 + length(word) <= columns then
                line = line .. " " .. word
            else
                lines[#lines + 1] = line
                line = word
            end
        end

        lines[#lines + 1] = line
    end

    return lines
end

---@param counts ZoneCodexCounts
local function carriedTypes(tab, counts)
    local carried = 0

    for _, entry in ipairs(tab.entries) do
        if (counts[entry.id] or 0) > 0 then
            carried = carried + 1
        end
    end

    return carried
end

---@param tabs ZoneCodexTab[]
---@param view ZoneCodexView
---@return string[]
function Model.tabLabels(tabs, view)
    local labels = {}

    for tabIndex, tab in ipairs(tabs) do
        labels[tabIndex] = (tabIndex == view.tabIndex and "> " or "   ") .. tab.title
    end

    return labels
end

---@param counts ZoneCodexCounts|nil
---@return string status Visible range, plus the carried summary for inventory tabs.
function Model.listStatus(tab, view, counts, visibleRows)
    local offset = view.offsets[view.tabIndex]
    local lastRow = math.min(#tab.entries, offset + visibleRows)
    local status = string.format("%d-%d of %d", offset + 1, lastRow, #tab.entries)

    if tab.tracksInventory then
        if counts then
            status = status .. string.format("   |   carrying %d of %d", carriedTypes(tab, counts), #tab.entries)
        else
            status = status .. "   |   carried counts unavailable"
        end
    end

    return status
end

---@param tabs ZoneCodexTab[]
---@param view ZoneCodexView
---@param counts ZoneCodexCounts|nil
---@param controls string Input help for the fallback overlay.
function Model.headerText(tabs, view, counts, visibleRows, controls)
    local tab = tabs[view.tabIndex]
    local status = Model.listStatus(tab, view, counts, visibleRows)

    return "ZONE CODEX   |   " .. tab.title .. "   |   " .. status .. "\n" .. controls
end

-- The second line of an Archive row: carried count, then the entry's first two facts.
---@param counts ZoneCodexCounts|nil
function Model.rowSubtitle(entry, counts)
    local parts = {}
    local carried = counts and counts[entry.id] or 0

    if carried > 0 then
        parts[1] = "Carried x" .. carried
    end

    for factIndex = 1, math.min(2, #entry.facts) do
        parts[#parts + 1] = entry.facts[factIndex][2]
    end

    return Model.truncate(table.concat(parts, "  |  "), ROW_SUBTITLE_COLUMNS)
end

---@class ZoneCodexRow
---@field icon string
---@field name string
---@field selected boolean
---@field subtitle string

---@return (ZoneCodexRow|false)[] rows One item per visible row; false past the last entry.
function Model.rowItems(tab, view, counts, visibleRows)
    local rows = {}
    local offset = view.offsets[view.tabIndex]

    for row = 1, visibleRows do
        local entryIndex = offset + row
        local entry = tab.entries[entryIndex]

        rows[row] = entry
                and {
                    icon = entry.icon or "",
                    name = Model.truncate(entry.name, ROW_NAME_COLUMNS),
                    selected = entryIndex == view.selections[view.tabIndex],
                    subtitle = Model.rowSubtitle(entry, counts),
                }
            or false
    end

    return rows
end

---@return string[] rows One string per visible row; rows past the last entry are empty.
function Model.listRows(tab, view, counts, visibleRows)
    local rows = {}
    local offset = view.offsets[view.tabIndex]

    for row = 1, visibleRows do
        local entryIndex = offset + row
        local entry = tab.entries[entryIndex]

        if entry then
            local marker = entryIndex == view.selections[view.tabIndex] and "> " or "   "
            local carried = counts and counts[entry.id] or 0
            local suffix = carried > 0 and ("  x" .. carried) or ""
            rows[row] = marker .. Model.truncate(entry.name, NAME_COLUMNS) .. suffix
        else
            rows[row] = ""
        end
    end

    return rows
end

---@param tab ZoneCodexTab
---@param entry ZoneCodexEntry
---@param counts ZoneCodexCounts|nil
---@return string[] lines Facts, carried count, bullets, and description (first on lore tabs); no title.
function Model.detailBody(tab, entry, counts, columns)
    local lines = {}

    local function add(text)
        for _, line in ipairs(Model.wrap(text, columns)) do
            lines[#lines + 1] = line
        end
    end

    local function separate()
        if #lines > 0 and lines[#lines] ~= "" then
            lines[#lines + 1] = ""
        end
    end

    if tab.descriptionFirst and entry.description ~= "" then
        add(entry.description)
        separate()
    end

    for _, fact in ipairs(entry.facts) do
        add(fact[1] .. ": " .. fact[2])
    end

    if tab.tracksInventory and #entry.sids > 0 then
        local carried = counts and counts[entry.id]
        add("Carried now: " .. (carried and tostring(carried) or "unknown"))
    end

    if #entry.bullets > 0 then
        separate()
        add(tab.bulletsTitle ~= "" and tab.bulletsTitle .. ":" or "Notes:")

        -- Wrapping collapses whitespace, so bullets get a hanging indent after wrapping.
        for _, bullet in ipairs(entry.bullets) do
            for lineIndex, line in ipairs(Model.wrap(bullet, columns - 2)) do
                lines[#lines + 1] = (lineIndex == 1 and "- " or "  ") .. line
            end
        end
    end

    if entry.description ~= "" and not tab.descriptionFirst then
        separate()
        add(entry.description)
    end

    if lines[#lines] == "" then
        lines[#lines] = nil
    end

    return lines
end

---@return string[] lines The title, a blank line, then the detail body.
function Model.detailLines(tab, entry, counts, columns)
    local lines = { entry.name, "" }

    for _, line in ipairs(Model.detailBody(tab, entry, counts, columns)) do
        lines[#lines + 1] = line
    end

    return lines
end

function Model.detailText(lines, view, visibleRows)
    local shown = {}
    local hasMore = view.detailOffset + visibleRows < #lines
    local lastRow = hasMore and visibleRows - 1 or visibleRows

    for row = 1, lastRow do
        local line = lines[view.detailOffset + row]

        if not line then
            break
        end

        shown[#shown + 1] = line
    end

    if hasMore then
        shown[#shown + 1] = "...  ] for more"
    end

    return table.concat(shown, "\n")
end

return Model
