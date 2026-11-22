-- ZoneCodex: a PDA encyclopedia of the Zone generated from the game's own data.
-- It lives on the PDA's unused Archive tab; Ctrl+E opens a viewport fallback when that slot is
-- taken or disabled. Input queues plain intents; all UObject access stays on the game-thread poll.
local ArchivePage = require("archive_page")
local Catalog = require("catalog")
local Inventory = require("inventory")
local Localizer = require("localizer")
local Model = require("model")
local Overlay = require("overlay")
local Pda = require("pda")
local Unreal = require("unreal")

assert(type(LoopInGameThreadWithDelay) == "function", "ZoneCodex requires UE4SS LoopInGameThreadWithDelay")

local CLAIM_RETRY_SECONDS = 5
local CULTURE_CHECK_SECONDS = 5
local MAX_QUEUED_INTENTS = 32
local MAX_CLICK_MISS_LOGS = 20
local POLL_MILLISECONDS = 100
local WHEEL_STEP = 3

local MODIFIER_LABELS = { ALT = "Alt", CONTROL = "Ctrl", SHIFT = "Shift" }

-- The Upgrades page's own sounds (BaseGame_UISounds): its category tabs post JournalTabSwitch
-- and picking an upgrade posts UpgradeItemSelect. Its scrolling is silent, so ours is too.
local SOUND_ROOT = "/Game/_STALKER2/Audio/WwiseAudio/Events/UI/PDA/"
local SOUNDS = {
    select = SOUND_ROOT .. "SFX_UI_Upgrade/SFX_UI_Upgrade_Switch.SFX_UI_Upgrade_Switch",
    tab = SOUND_ROOT .. "SFX_PDA_JournalTabSwitch.SFX_PDA_JournalTabSwitch",
}

local NAVIGATION_KEYS = {
    { intent = "previousTab", key = "LEFT_ARROW" },
    { intent = "nextTab", key = "RIGHT_ARROW" },
    { intent = "previousEntry", key = "UP_ARROW" },
    { intent = "nextEntry", key = "DOWN_ARROW" },
    { intent = "previousPage", key = "PAGE_UP" },
    { intent = "nextPage", key = "PAGE_DOWN" },
    { intent = "detailUp", key = "OEM_FOUR" },
    { intent = "detailDown", key = "OEM_SIX" },
}

local source = debug and debug.getinfo and debug.getinfo(1, "S").source or ""
local modDirectory = source:match("^@(.*)[\\/][Ss]cripts[\\/][^\\/]+$") or "ue4ss\\Mods\\ZoneCodex"
local config, templateTabs, fallbacks = Catalog.load(modDirectory)

-- English until the game thread can ask the game for the player's language; see localize().
local tabs = Localizer.resolveTabs(templateTabs, function()
    return nil
end, fallbacks)

-- Codex state is owned by this mod's single Lua state for the whole game session.
local archive
local archiveNotice
local claimedBefore = false
local clickMissLogs = 0
local counts, countsReadAt, countsTabIndex
local detailLineCount = 0
local localizedCulture
local needsRender = false
local nextClaimAttempt = 0
local nextCultureCheck = 0
local pendingIntents = {}
local reportedErrors = {}
local toggleLabel
local view = Model.new(#tabs)

local function queue(intent)
    if #pendingIntents < MAX_QUEUED_INTENTS then
        pendingIntents[#pendingIntents + 1] = intent
    end
end

local function bind(keyName, intent)
    if not Key[keyName] then
        Unreal.log("UE4SS has no Key." .. keyName .. "; '" .. intent .. "' is unbound")
        return false
    end

    RegisterKeyBind(Key[keyName], function()
        queue(intent)
    end)

    return true
end

local function report(name, errorMessage)
    if errorMessage == nil then
        reportedErrors[name] = nil
    elseif reportedErrors[name] ~= errorMessage then
        reportedErrors[name] = errorMessage
        Unreal.log(name .. " ERROR: " .. errorMessage)
    end
end

-- Another mod owning the Archive slot is expected, not an error; say so once per change.
local function noteArchive(message)
    if message and message ~= archiveNotice then
        Unreal.log(message)
    end

    archiveNotice = message
end

-- The Archive page and the fallback overlay fit different numbers of list rows and detail lines.
local function listRowCount()
    return archive and config.ArchiveRows or config.VisibleRows
end

local function detailLineLimit()
    return archive and config.ArchiveDetailLines or config.VisibleRows
end

-- Game text follows the player's language: templates are re-expanded the first time the culture
-- is read and whenever it changes. Entries re-sort by localized name, so the view starts over.
local function localize(now)
    if now < nextCultureCheck then
        return
    end

    nextCultureCheck = now + CULTURE_CHECK_SECONDS

    local culture = Unreal.currentCulture() or "unknown"

    if culture == localizedCulture then
        return
    end

    local resolved, stats = Localizer.resolveTabs(templateTabs, Unreal.localizedText, fallbacks)
    local tabIndex = view.tabIndex

    tabs, localizedCulture = resolved, culture
    view = Model.new(#tabs)
    view.tabIndex = tabIndex
    needsRender, countsTabIndex = true, nil
    Unreal.log(
        string.format("text language %s: %d game strings, %d English fallbacks", culture, stats.localized, stats.fallback)
    )
end

local function closeViewport(reason)
    if Overlay.isShown() then
        Overlay.hide()

        if reason then
            Unreal.log("closed: " .. reason)
        end
    end
end

local function openViewport(pdaOpen)
    if #tabs == 0 then
        Unreal.log("nothing to show: codex_data.lua is missing or empty")
        return
    end

    if config.RequirePda and not pdaOpen then
        Unreal.log("open the PDA first (" .. Pda.describe() .. "); or set RequirePda = false in config.lua")
        return
    end

    local controller = Unreal.playerController()

    if not controller then
        Unreal.log("no player controller yet; try again in game")
        return
    end

    Overlay.show(controller, { lineHeight = config.LineHeight, tabCount = #tabs, visibleRows = config.VisibleRows })
    needsRender, countsTabIndex = true, nil
end

local function claimArchive(bookView, now)
    if now < nextClaimAttempt then
        return
    end

    nextClaimAttempt = now + CLAIM_RETRY_SECONDS

    local candidate = Pda.archive(bookView)

    if not candidate then
        noteArchive("PDA Archive tab not found (game update?); use " .. toggleLabel .. " instead")
        return
    end

    local owner = Pda.archiveOwner(candidate, claimedBefore)

    if owner then
        noteArchive(owner .. "; ZoneCodex stays on " .. toggleLabel .. " instead")
        return
    end

    local controller = Unreal.playerController()

    if not controller then
        return
    end

    local titles = {}

    for index, tab in ipairs(tabs) do
        titles[index] = tab.title
    end

    closeViewport("moving to the PDA Archive tab")
    ArchivePage.show(candidate, controller, { rows = config.ArchiveRows, tabTitles = titles })
    Pda.hidePlaceholder(candidate)
    archive, claimedBefore = candidate, true
    needsRender, countsTabIndex = true, nil
    noteArchive(nil)
    Unreal.log("added to the PDA Archive tab")
end

local function navigate(intent)
    local rows = listRowCount()
    local detailLines = detailLineLimit()
    local tabBefore = view.tabIndex

    if intent == "previousTab" or intent == "nextTab" then
        Model.switchTab(view, tabs, intent == "nextTab" and 1 or -1)
    elseif intent == "previousEntry" or intent == "nextEntry" then
        Model.move(view, tabs, intent == "nextEntry" and 1 or -1, rows)
    elseif intent == "previousPage" or intent == "nextPage" then
        Model.move(view, tabs, intent == "nextPage" and rows or -rows, rows)
    elseif intent == "detailUp" or intent == "detailDown" then
        local direction = intent == "detailDown" and 1 or -1

        -- The page's scroll panel moves by itself; the overlay and fallback page by line.
        if not (archive and ArchivePage.scrollDetail(direction)) then
            Model.scrollDetail(view, direction * (detailLines - 2), detailLineCount, detailLines)
        end
    elseif intent == "click" then
        local kind, index, mouse = ArchivePage.clickTarget()

        if kind == "tab" then
            Model.selectTab(view, tabs, index)
        elseif kind == "row" then
            Model.selectRow(view, tabs, index, rows)
        elseif clickMissLogs < MAX_CLICK_MISS_LOGS then
            -- Clicks elsewhere on the PDA land here too; the position tells them apart.
            clickMissLogs = clickMissLogs + 1
            local position = mouse and string.format("%.0f,%.0f", mouse.X, mouse.Y) or "unavailable"
            Unreal.log("click matched no tab or row (cursor " .. position .. "; hover " .. ArchivePage.hoverReport() .. ")")
        end
    end

    if view.tabIndex ~= tabBefore then
        countsTabIndex = nil
    end

    needsRender = true
end

local function refreshCounts(now)
    local tab = tabs[view.tabIndex]
    local ok, result, errorMessage = pcall(Inventory.read, tab)

    countsReadAt, countsTabIndex = now, view.tabIndex

    if ok and result then
        counts = result
        report("inventory", nil)
    else
        counts = nil
        report("inventory", tostring(ok and errorMessage or result))
    end

    needsRender = true
end

local PAGE_CONTROLS = "Click, wheel or arrows: browse     PgUp/PgDn: page     Q/E: PDA pages"

local function renderPage(tab, entry, tabCounts)
    local rows, lines = config.ArchiveRows, config.ArchiveDetailLines
    local bodyLines = Model.detailBody(tab, entry, tabCounts, config.ArchiveDetailColumns)
    local subtitle = tab.title
    local carried = tabCounts and tabCounts[entry.id]
    local body

    if carried and carried > 0 then
        subtitle = subtitle .. "  |  Carried: " .. carried
    end

    -- Mutants picture their render beside the text and keep the trophy part in the header.
    local headerIcon = entry.detailIcon ~= "" and entry.detailIcon or (entry.image == "" and entry.icon or "")

    detailLineCount = #bodyLines

    if ArchivePage.hasDetailScroll() then
        body = table.concat(bodyLines, "\n")
    else
        Model.scrollDetail(view, 0, detailLineCount, lines)
        body = Model.detailText(bodyLines, view, lines)
    end

    ArchivePage.setContent({
        controls = PAGE_CONTROLS,
        detail = {
            body = body,
            icon = headerIcon,
            image = entry.image,
            key = tab.id .. "/" .. entry.id,
            subtitle = subtitle,
            title = entry.name,
        },
        maskIcons = tab.maskIcons,
        rows = Model.rowItems(tab, view, tabCounts, rows),
        selectedTab = view.tabIndex,
        status = tab.title .. "     " .. Model.listStatus(tab, view, tabCounts, rows),
    })
end

local function renderViewport(tab, entry, tabCounts)
    local rows = config.VisibleRows
    local detailLines = Model.detailLines(tab, entry, tabCounts, config.DetailColumns)
    local controls = "Left/Right tab   Up/Down select   PgUp/PgDn page   [ ] scroll details   " .. toggleLabel .. " close"

    detailLineCount = #detailLines
    Model.scrollDetail(view, 0, detailLineCount, rows)
    Overlay.setTexts({
        detail = Model.detailText(detailLines, view, rows),
        header = Model.headerText(tabs, view, tabCounts, rows, controls),
        rows = Model.listRows(tab, view, tabCounts, rows),
        tabs = Model.tabLabels(tabs, view),
    })
end

local function viewSnapshot()
    local tabIndex = view.tabIndex

    return {
        selection = view.selections[tabIndex],
        tabIndex = tabIndex,
    }
end

-- One Upgrades sound per poll: a tab switch wins over a selection change; scrolling is silent.
local function playChangeSound(before)
    if not config.Sounds then
        return
    end

    local after = viewSnapshot()
    local sound

    if after.tabIndex ~= before.tabIndex then
        sound = SOUNDS.tab
    elseif after.selection ~= before.selection then
        sound = SOUNDS.select
    end

    if sound then
        Unreal.playSound(sound)
    end
end

local function render()
    local tab = tabs[view.tabIndex]
    local tabCounts = tab.tracksInventory and counts or nil
    local entry = Model.selectedEntry(tabs, view)

    if archive then
        renderPage(tab, entry, tabCounts)
    else
        renderViewport(tab, entry, tabCounts)
    end

    needsRender = false
end

local function tick(now)
    local intents = pendingIntents
    pendingIntents = {}

    local pageGone = archive ~= nil and not Unreal.isValid(archive.page)
    local pageLost = archive ~= nil and (pageGone or not ArchivePage.isAlive())

    if (Overlay.isShown() and not Overlay.isAlive()) or pageLost then
        Overlay.hide()
        ArchivePage.hide()
        Pda.reset()
        -- A surviving page keeps our shown Archive button, so re-adding must not read it as foreign.
        archive, claimedBefore, nextClaimAttempt = nil, claimedBefore and not pageGone, 0
        Unreal.log("codex widgets were destroyed (level change?); will re-add them")
    end

    local bookView = Pda.find(now)
    local pdaOpen = bookView ~= nil and Pda.isOpen(bookView)

    if pdaOpen or Overlay.isShown() or #intents > 0 then
        localize(now)
    end

    if pdaOpen and config.UseArchiveTab and #tabs > 0 then
        if not archive then
            claimArchive(bookView, now)
        end

        if archive then
            Pda.showArchiveButton(archive)
        end
    end

    local pageActive = archive ~= nil and pdaOpen and Pda.isArchiveActive(archive)

    if not pageActive then
        ArchivePage.forgetHover()
    end

    local before = viewSnapshot()

    for _, intent in ipairs(intents) do
        if intent == "toggle" then
            if archive then
                Unreal.log("ZoneCodex is on the PDA's Archive tab; " .. toggleLabel .. " is only the fallback")
            elseif Overlay.isShown() then
                closeViewport()
            else
                openViewport(pdaOpen)
            end
        elseif pageActive or Overlay.isShown() then
            navigate(intent)
        end
    end

    if Overlay.isShown() and config.RequirePda and not pdaOpen then
        closeViewport("PDA closed")
        return
    end

    if pageActive then
        local listNotches = ArchivePage.takeWheel()

        if listNotches ~= 0 then
            Model.scrollList(view, tabs, listNotches * WHEEL_STEP, listRowCount())
            needsRender = true
        end

        playChangeSound(before)
    end

    if not (pageActive or Overlay.isShown()) then
        return
    end

    local isStale = countsTabIndex ~= view.tabIndex or now - countsReadAt >= config.RefreshSeconds

    if tabs[view.tabIndex].tracksInventory and isStale then
        refreshCounts(now)
    end

    if needsRender then
        render()
    end

    if pageActive then
        ArchivePage.updateHover()
    end
end

local toggleKey = config.Key
local modifier = config.Modifier

if not Key[toggleKey] then
    Unreal.log("unknown Key '" .. toggleKey .. "' in config.lua; using E")
    toggleKey = "E"
end

if modifier ~= "" and not (ModifierKey and ModifierKey[modifier]) then
    Unreal.log("unknown Modifier '" .. modifier .. "' in config.lua; using CONTROL")
    modifier = "CONTROL"
end

if modifier == "" then
    toggleLabel = toggleKey
    bind(toggleKey, "toggle")
else
    toggleLabel = (MODIFIER_LABELS[modifier] or modifier) .. "+" .. toggleKey
    RegisterKeyBind(Key[toggleKey], { ModifierKey[modifier] }, function()
        queue("toggle")
    end)
end

for _, binding in ipairs(NAVIGATION_KEYS) do
    bind(binding.key, binding.intent)
end

local clickOk, clickError = pcall(function()
    RegisterKeyBind(Key.LEFT_MOUSE_BUTTON, function()
        queue("click")
    end)
end)

if not clickOk then
    Unreal.log("click keybind unavailable (" .. tostring(clickError) .. "); use the arrow keys")
end

LoopInGameThreadWithDelay(POLL_MILLISECONDS, function()
    local ok, errorMessage = pcall(tick, os.time())

    report("poll", not ok and tostring(errorMessage) or nil)

    -- Page widgets only show on the Archive tab, so only the viewport fallback is torn down here.
    if not ok and Overlay.isShown() then
        local closed, closeError = pcall(closeViewport, "error")

        if not closed then
            Unreal.log("cleanup ERROR: " .. tostring(closeError))
        end
    end

    return false
end)

local entryCount = 0

for _, tab in ipairs(tabs) do
    entryCount = entryCount + #tab.entries
end

Unreal.log(string.format("%d tabs, %d entries; PDA Archive tab, or %s as a fallback", #tabs, entryCount, toggleLabel))
