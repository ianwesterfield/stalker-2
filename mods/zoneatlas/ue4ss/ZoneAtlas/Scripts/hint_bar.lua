local Catalog = require("catalog")
local Unreal = require("unreal")
local WorldMap = require("world_map")

local HintBar = {}
local state = { errors = 0, nextTry = 0, nextSync = 0, settle = 0 }

local function property(object, name)
    local ok, value = pcall(function()
        return object[name]
    end)

    if ok and Unreal.isValid(value) then
        return value
    end
end

local function textOf(widget)
    local ok, text = pcall(function()
        return widget:GetText():ToString()
    end)

    return ok and type(text) == "string" and text or ""
end

local function isShown(widget)
    local ok, visibility = pcall(function()
        return widget:GetVisibility()
    end)

    return ok and visibility ~= 1 and visibility ~= 2
end

local function setVisibility(widget, visibility)
    if not Unreal.isValid(widget) then
        return
    end

    local ok, current = pcall(function()
        return widget:GetVisibility()
    end)

    if not ok or current ~= visibility then
        widget:SetVisibility(visibility)
    end
end

local function keyCap(hint)
    local switcher = property(hint, "PlatformSwitcher")
    
    local ok, view = pcall(function()
        return switcher:GetActiveWidget()
    end)
    
    local cap = ok and Unreal.isValid(view) and property(view, "HintIconImage")

    if cap and property(cap, "HintChar") then
        return cap
    end
end

local function capShowsCharacter(cap)
    local character = property(cap, "HintChar")
    return character ~= nil and isShown(character) and textOf(character) ~= ""
end

local function pickSource(page)
    local fallback

    for _, name in ipairs({
        "MoveToPlayerPositionHint",
        "ShowLegendHint",
        "ShowMarkerSelectorHint",
        "SelectMarkerHint",
        "ChangeZoomLevelHint",
    }) do
        local hint = property(page, name)
        local cap = hint and keyCap(hint)

        if cap then
            if capShowsCharacter(cap) then
                return hint, cap, name
            end

            fallback = fallback or { hint, cap, name }
        end
    end

    if fallback then
        return table.unpack(fallback)
    end
end

local function liveLabel(hint)
    for _, name in ipairs({ "RightText", "LeftText" }) do
        local label = property(hint, name)

        if label and isShown(label) and textOf(label) ~= "" then
            return label, name
        end
    end
end

local function copyTextSettings(destination, source)
    pcall(function()
        local settings = source.TextSettings
        destination.TextSettings.FontStyleId = settings.FontStyleId
        destination.TextSettings.bUseFontColor = settings.bUseFontColor
        destination.TextSettings.TextTransformPolicy = settings.TextTransformPolicy
    end)

    pcall(function()
        destination.bEnableStyleManager = source.bEnableStyleManager
    end)
end

local function copyTextLook(destination, source)
    local destinationText, sourceText = property(destination, "CommonTextObj"), property(source, "CommonTextObj")

    if destinationText and sourceText then
        pcall(function()
            destinationText:SetFont(sourceText.Font)
        end)
        
        pcall(function()
            local color = sourceText.ColorAndOpacity
            local specified = color.SpecifiedColor
            destinationText:SetColorAndOpacity({
                SpecifiedColor = { R = specified.R, G = specified.G, B = specified.B, A = specified.A },
                ColorUseRule = color.ColorUseRule,
            })
        end)

        pcall(function()
            destinationText:SetTextTransformPolicy(sourceText.TextTransformPolicy)
        end)
    end
end

local function styleCap(copyBrushes)
    local sourceCap = keyCap(state.source)

    if not sourceCap then
        return false
    end

    local hasCharacter = capShowsCharacter(sourceCap)

    for _, name in ipairs({ "HintBackground", "HintImage" }) do
        local destination, source = property(state.cap, name), property(sourceCap, name)

        if destination and source then
            setVisibility(destination, hasCharacter and source:GetVisibility() or (name == "HintImage" and 1 or 3))

            if hasCharacter and copyBrushes then
                pcall(function()
                    local resource = source.Brush.ResourceObject

                    if Unreal.isValid(resource) then
                        destination:SetBrushResourceObject(resource)
                    end
                end)

                pcall(function()
                    local size = source.Brush.ImageSize
                    destination:SetDesiredSizeOverride({ X = size.X, Y = size.Y })
                end)
                
                pcall(function()
                    local color = source.ColorAndOpacity
                    destination:SetColorAndOpacity({ R = color.R, G = color.G, B = color.B, A = color.A })
                end)
            end
        end
    end

    local character = property(state.cap, "HintChar")

    if character then
        if textOf(character) ~= Catalog.config.Key then
            character:SetText(FText(Catalog.config.Key))
        end

        setVisibility(character, 3)
    end

    return true
end

local function build(page)
    local source, sourceCap, sourceName = pickSource(page)

    if not source then
        return false
    end

    local row = source:GetParent()
    assert(Unreal.isValid(row), sourceName .. " has no parent panel")
    local cap = Unreal.createWidget(sourceCap:GetClass())
    local label = Unreal.createWidget(Unreal.TEXT_WIDGET)
    local sourceText, side = liveLabel(source)

    if sourceText then
        copyTextSettings(label, sourceText)
    end

    label:SetText(FText(Catalog.config.HintLabel))
    local first, second = cap, label

    if side == "LeftText" then
        first, second = label, cap
    end

    local padding = { Left = 0, Top = 0, Right = 0, Bottom = 0 }
    pcall(function()
        local sourcePadding = source.Slot.Padding
        padding = {
            Left = sourcePadding.Left,
            Top = sourcePadding.Top,
            Right = sourcePadding.Right,
            Bottom = sourcePadding.Bottom,
        }
    end)

    for index, widget in ipairs({ first, second }) do
        local slot = row:AddChild(widget)
        pcall(function()
            slot:SetPadding({
                Left = index == 1 and padding.Left or 0,
                Top = padding.Top,
                Right = index == 1 and 6 or padding.Right,
                Bottom = padding.Bottom,
            })
        end)
        pcall(function()
            slot:SetVerticalAlignment(2)
        end)
        pcall(function()
            slot:SetSize({ SizeRule = 0, Value = 1 })
        end)
    end

    state.cap, state.label, state.page, state.source, state.sourceText = cap, label, page, source, sourceText
    state.nextSync, state.settle = 0, 10
    Unreal.log("map hint added next to " .. sourceName)
    return true
end

function HintBar.drop()
    state.cap, state.label, state.page, state.source, state.sourceText = nil, nil, nil, nil, nil
end

local function isAlive()
    if
        Unreal.isValid(state.page)
        and Unreal.isValid(state.source)
        and Unreal.isValid(state.cap)
        and Unreal.isValid(state.label)
    then
        return true
    end

    HintBar.drop()
    return false
end

function HintBar.isHovered()
    if not isAlive() or WorldMap.currentPage() ~= state.page then
        return false
    end

    local ok, hovered = pcall(function()
        return state.cap:IsHovered() or state.label:IsHovered()
    end)
    return ok and hovered == true
end

function HintBar.tick(now)
    if not Catalog.config.ShowHint or state.disabled then
        return
    end

    local page = WorldMap.currentPage()

    if not page then
        HintBar.drop()
        return
    end

    if state.page ~= page or not isAlive() then
        HintBar.drop()
        state.page = page

        if now < state.nextTry then
            return
        end

        state.nextTry = now + 2
        local ok, errorMessage = pcall(build, page)

        if not ok then
            state.errors = state.errors + 1
            state.disabled = state.errors >= 3
            Unreal.log("map hint ERROR: " .. tostring(errorMessage))

            if state.disabled then
                Unreal.log("map hint disabled for this session")
            end
        end

        return
    end

    if state.settle > 0 or now >= state.nextSync then
        state.nextSync = now + 0.5
        local settling = state.settle > 0
        state.settle = math.max(0, state.settle - 1)
        local ok, keyboard = pcall(styleCap, settling)

        if not ok and not state.warned then
            state.warned = true
            Unreal.log("map hint style: " .. tostring(keyboard))
        end

        local visibility = (ok and keyboard) and 0 or 1
        setVisibility(state.cap, visibility)
        setVisibility(state.label, visibility)

        if settling and Unreal.isValid(state.sourceText) then
            copyTextLook(state.label, state.sourceText)
        end
    end
end

return HintBar
