-- The PDA (W_PDABookView_C) and its unused Archive tab. Game thread only.
-- The game ships an Archive button (ButtonId "Bestiary") collapsed and disabled, and an
-- "In Progress" placeholder page in the PDA's page switcher; ZoneCodex borrows both.
local Unreal = require("unreal")

local Pda = {}

local BOOK_VIEW_CLASS = "W_PDABookView_C"
local SEARCH_SECONDS = 2
local VISIBILITY_COLLAPSED = 1
local VISIBILITY_VISIBLE = 0

-- Book view cached for the session; cleared on level changes via Pda.reset.
local bookView, bookViewSeen
local nextSearch = 0

local notifyOk, notifyError = pcall(function()
    NotifyOnNewObject("/Script/Stalker2.PDAView", function(object)
        bookViewSeen = object
    end)
end)

if not notifyOk then
    Unreal.log("PDA notifications unavailable (" .. tostring(notifyError) .. "); scanning instead")
end

local function call(object, functionName, ...)
    local arguments = table.pack(...)
    local ok, value = pcall(function()
        return object[functionName](object, table.unpack(arguments, 1, arguments.n))
    end)

    return ok and value or nil
end

function Pda.reset()
    bookView, bookViewSeen, nextSearch = nil, nil, 0
end

---@param now number os.time seconds; scans are throttled because FindAllOf walks every object.
function Pda.find(now)
    if bookViewSeen and Unreal.isValid(bookViewSeen) and not Unreal.isDefault(bookViewSeen) then
        bookView = bookViewSeen
    end

    bookViewSeen = nil

    if Unreal.isValid(bookView) then
        return bookView
    end

    bookView = nil

    if now < nextSearch then
        return nil
    end

    nextSearch = now + SEARCH_SECONDS

    for _, candidate in ipairs(FindAllOf(BOOK_VIEW_CLASS) or {}) do
        if Unreal.isValid(candidate) and not Unreal.isDefault(candidate) then
            bookView = candidate
            return bookView
        end
    end

    return nil
end

function Pda.isOpen(view)
    return call(view, "IsInViewport") == true and call(view, "IsVisible") ~= false
end

---@return { button: any, page: any, root: any, switcher: any }|nil archive
function Pda.archive(view)
    local ok, archive = pcall(function()
        local page = view.BestiaryPage

        return {
            button = view.NavigationPanel.BestiaryBtn,
            page = page,
            root = page.WidgetTree.RootWidget,
            switcher = view.Switcher,
        }
    end)

    if not ok then
        return nil
    end

    for _, part in pairs(archive) do
        if not Unreal.isValid(part) then
            return nil
        end
    end

    return archive
end

-- Vanilla state is a collapsed button and a page holding only the placeholder text.
-- Anything else means another Archive tab mod got there first.
---@param buttonShownByUs boolean ZoneCodex claimed this slot before, so a shown button is ours.
---@return string|nil reason Why the slot is taken, or nil when it is free.
function Pda.archiveOwner(archive, buttonShownByUs)
    if not buttonShownByUs and call(archive.button, "GetVisibility") ~= VISIBILITY_COLLAPSED then
        return "the Archive button is already shown by another mod"
    end

    if call(archive.root, "GetChildrenCount") ~= 1 then
        return "the Archive page already has content from another mod"
    end

    return nil
end

function Pda.hidePlaceholder(archive)
    local placeholder = call(archive.root, "GetChildAt", 0)

    if Unreal.isValid(placeholder) then
        placeholder:SetVisibility(VISIBILITY_COLLAPSED)
    end
end

-- The game re-applies its own button state, so this runs every poll while the PDA is open.
function Pda.showArchiveButton(archive)
    if call(archive.button, "GetVisibility") ~= VISIBILITY_VISIBLE then
        archive.button:SetVisibility(VISIBILITY_VISIBLE)
    end

    if call(archive.button, "GetIsEnabled") ~= true then
        archive.button:SetIsEnabled(true)
    end
end

function Pda.isArchiveActive(archive)
    local active = call(archive.switcher, "GetActiveWidgetIndex")
    local index = call(archive.switcher, "GetChildIndex", archive.page)

    return type(active) == "number" and active >= 0 and active == index
end

function Pda.describe()
    if not Unreal.isValid(bookView) then
        return "no " .. BOOK_VIEW_CLASS .. " yet (PDA not opened since loading?)"
    end

    return BOOK_VIEW_CLASS .. " exists but is not on screen"
end

return Pda
