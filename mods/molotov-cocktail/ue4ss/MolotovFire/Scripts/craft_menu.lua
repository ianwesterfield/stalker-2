-- "Make Molotov" inventory context-menu entry.
-- Menu rows are created per-open; MenuItemWidgetClass + CreateWidget + AddChild
-- renders a real row, but native code binds row button delegates only for ITS OWN
-- rows during population — a spawned row's click/hover events never dispatch and
-- Lua cannot AddDynamic. So we own the click: row:IsHovered() (callable native
-- UFunction) + an LMB keybind.
local Crafting = require("crafting")
local Unreal = require("unreal")

local CraftMenu = {}

-- The injected row for the currently open menu; cleared whenever the menu or its
-- selected slot changes. `busy` spans one craft chain.
CraftMenu.state = {
    entry = nil,
    menu = nil,
    slot = nil,
    busy = false,
    hovered = false,
}

local CRAFT_ICONS = {
    ["Texture2D /Game/GameLite/FPS_Game/UIRemaster/UITextures/Inventory/Consumable/T_cns_cossacks_vodka_01.T_cns_cossacks_vodka_01"] = true,
    ["Texture2D /Game/GameLite/FPS_Game/UIRemaster/UITextures/Inventory/Consumable/T_cns_bandage_01.T_cns_bandage_01"] = true,
}

local state = CraftMenu.state
local lastSelectionError
local seenMenus = {}

local function selectedIcon(slot)
    assert(Unreal.isAlive(slot), "missing clicked inventory slot")
    assert(Unreal.isAlive(slot.ItemImage), "missing selected item image")
    local image = slot.ItemImage.ImageObj
    assert(Unreal.isAlive(image), "missing selected item ImageObj")
    local resource = image.Brush.ResourceObject
    assert(Unreal.isAlive(resource), "missing selected icon material")

    -- Inventory icons are dynamic materials; the brush resource itself
    -- identifies a widget instance, not an ingredient.
    local icon

    resource.TextureParameterValues:ForEach(function(_, value)
        local parameter = value:get()

        if parameter.ParameterInfo.Name:ToString() == "Icon" then
            assert(Unreal.isAlive(parameter.ParameterValue), "missing Icon texture")
            icon = parameter.ParameterValue:GetFullName()
        end
    end)

    assert(icon, "selected material has no Icon texture")
    return icon
end

-- Address of the clicked slot when `menu` is the open right-click menu of a vodka
-- or bandage; nil otherwise.
function CraftMenu.craftSelection(menu)
    local ok, result = pcall(function()
        if not Unreal.isAlive(menu) or not menu:IsVisible() then
            return nil
        end

        local menuAddress = Unreal.address(menu)

        if not menuAddress then
            return nil
        end

        for _, inventory in ipairs(FindAllOf("InventoryNew") or {}) do
            if
                Unreal.isAlive(inventory)
                and not inventory:GetFullName():find("Default__")
                and inventory:IsVisible()
                and Unreal.isAlive(inventory.RightClickMenuWidget)
                and Unreal.address(inventory.RightClickMenuWidget) == menuAddress
            then
                local slot = inventory.CurrClickedItem

                if CRAFT_ICONS[selectedIcon(slot)] then
                    return assert(Unreal.address(slot), "missing selected slot address")
                end

                return nil
            end
        end
    end)

    if not ok then
        if lastSelectionError ~= tostring(result) then
            lastSelectionError = tostring(result)
            Unreal.log("craft: selection unavailable; row suppressed: " .. lastSelectionError)
        end

        return nil
    end

    lastSelectionError = nil
    return result
end

local function clearEntry()
    local entry = state.entry
    state.entry, state.menu, state.slot, state.hovered = nil, nil, nil, false

    if Unreal.isAlive(entry) then
        entry:RemoveFromParent()
    end
end

function CraftMenu.injectEntry(menu)
    local slot = CraftMenu.craftSelection(menu)

    if not slot then
        return
    end

    local itemClass, box

    pcall(function()
        itemClass = menu.MenuItemWidgetClass
    end)

    pcall(function()
        box = menu.Menu
    end)

    if not (itemClass and box and box:IsValid()) then
        return
    end

    -- no makings, no menu row
    local vodka, bandage = Crafting.playerCounts()

    if not (vodka and vodka >= 1 and bandage >= 1) then
        return
    end

    local widgetLibrary = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
    local row = widgetLibrary:Create(menu, itemClass, nil)

    if not (row and row:IsValid()) then
        return
    end

    pcall(function()
        row.Label:SetText(FText("Craft molotov cocktail"))
    end)

    box:AddChild(row)

    -- the game styles rows inside its native hover handlers — they're plain
    -- UFunctions, so drive them ourselves: settle into unhovered now, mirror
    -- IsHovered() after
    pcall(function()
        row:OnButtonUnHovered()
    end)

    state.entry, state.hovered = row, false
    state.menu, state.slot = menu, slot
    Unreal.log("craft: Molotov on the menu")
end

local function mirrorHover()
    local entry = Unreal.isAlive(state.entry) and state.entry or nil

    if not entry or CraftMenu.craftSelection(state.menu) ~= state.slot then
        clearEntry()
        return
    end

    local isHovered = entry:IsHovered()

    if isHovered ~= state.hovered then
        state.hovered = isHovered

        if isHovered then
            entry:OnButtonHovered()
        else
            entry:OnButtonUnHovered()
        end
    end
end

local function scheduleInjection(menu)
    ExecuteInGameThreadWithDelay(50, function()
        ExecuteInGameThread(function()
            local ok, errorMessage = pcall(function()
                if Unreal.isAlive(menu) then
                    CraftMenu.injectEntry(menu)
                end
            end)

            if not ok then
                Unreal.log("craft: menu injection ERR " .. tostring(errorMessage))
            end
        end)
    end)
end

local function watchMenus()
    for _, menu in ipairs(FindAllOf("W_RightClickMenu_C") or {}) do
        if menu:IsValid() and not menu:GetFullName():find("Default__") then
            local menuAddress = Unreal.address(menu)

            if menuAddress and not seenMenus[menuAddress] then
                seenMenus[menuAddress] = true
                clearEntry()
                scheduleInjection(menu)
            end
        end
    end
end

local function hideMenu()
    pcall(function()
        local inventory = Unreal.liveInstance("InventoryNew")

        if inventory then
            inventory:HideRightClickMenu()
        end
    end)
end

local function handleClick()
    local entry = Unreal.isAlive(state.entry) and state.entry or nil

    if not entry then
        state.entry = nil -- menu died without a craft; re-cheapen the gate
        return
    end

    if not entry:IsHovered() then
        return
    end

    if CraftMenu.craftSelection(state.menu) ~= state.slot then
        Unreal.log("craft: ignored stale menu selection")
        clearEntry()
        return
    end

    clearEntry()
    local vodka, bandage = Crafting.playerCounts()

    if not (vodka and vodka >= 1 and bandage >= 1) then
        hideMenu()
        return
    end

    state.busy = true
    Unreal.log("craft: Make Molotov clicked")
    hideMenu()

    -- fire the removals directly: the quest gate adds a hop and does not gate anyway
    Crafting.craft("menu", "MolotovCraft_TakeVodka", function()
        state.busy = false
    end)
end

function CraftMenu.start()
    -- hover mirror: native rows get this from their bound delegates; ours is unbound
    LoopInGameThreadWithDelay(60, function()
        if not state.entry then
            return false
        end

        ExecuteInGameThread(function()
            local ok, errorMessage = pcall(mirrorHover)

            if not ok then
                Unreal.log("craft: hover ERR " .. tostring(errorMessage))
            end
        end)

        return false
    end)

    LoopInGameThreadWithDelay(120, function()
        ExecuteInGameThread(function()
            pcall(watchMenus)
        end)

        return false
    end)

    -- LMB fires on every trigger pull: the plain-field gate keeps combat cost at a nil check
    RegisterKeyBind(Key.LEFT_MOUSE_BUTTON, function()
        if not state.entry or state.busy then
            return
        end

        ExecuteInGameThread(function()
            local ok, errorMessage = pcall(handleClick)

            if not ok then
                Unreal.log("craft: menu click ERR " .. tostring(errorMessage))
            end
        end)
    end)
end

return CraftMenu
