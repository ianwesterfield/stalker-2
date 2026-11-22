-- The codex as a styled PDA Archive page, laid out like the vanilla Upgrades page: category
-- buttons over an icon list on the left, a titled detail pane on the right, and a hint bar.
-- Everything is a child of the page's root overlay, positioned by slot padding, so the layout
-- needs no page size. Images are plain UMG Images; text uses the game's own font style ids.
-- Game thread only.
local Unreal = require("unreal")

local ArchivePage = {}

local ALIGN_BOTTOM, ALIGN_CENTER, ALIGN_FILL, ALIGN_LEFT, ALIGN_RIGHT, ALIGN_TOP = 3, 2, 0, 1, 3, 1
local BRUSH_DRAW_IMAGE, BRUSH_DRAW_NONE = 3, 0
local CONSUME_WHEEL_ALWAYS = 1
local VISIBILITY_COLLAPSED, VISIBILITY_HIT_TEST_INVISIBLE, VISIBILITY_VISIBLE = 1, 3, 0
local VISIBILITY_SELF_HIT_TEST_INVISIBLE = 4

-- UE4SS keybinds can't see the mouse wheel, so hidden ScrollBoxes catch it over the list. Each
-- one rests at WHEEL_CENTER; the distance a wheel moved it, in Slate.GlobalScrollAmount units
-- per notch, is read and reset every poll. Bigger jumps are layout resets, not the wheel.
local WHEEL_CENTER = 2000
local WHEEL_CONTENT_HEIGHT = 3 * WHEEL_CENTER
local WHEEL_MAX_DELTA = 1000
local WHEEL_NOTCH = 32

-- Slate units, measured from W_UpgradePage and its slot widgets.
local DETAIL_ICON_SIZE = 128
local DETAIL_IMAGE_GAP = 24
local DETAIL_IMAGE_HEIGHT = 330
local DETAIL_IMAGE_WIDTH = 520
local DETAIL_INSET = 30
local DETAIL_SCROLL_STEP = 240
local DETAIL_TEXT_WIDTH = 700
local DETAIL_TOP = 25
local DIVIDER_HEIGHT = 6
local HINT_BAR_HEIGHT = 76
local LEFT_LINE_WIDTH = 9
local LIST_FRAME_BOTTOM_HEIGHT = 469.5
local LIST_FRAME_TOP_HEIGHT = 16
local LIST_WIDTH = 505
local ROW_HEIGHT = 64
local ROW_ICON_HEIGHT = 46
local ROW_ICON_LEFT = 16
local ROW_ICON_WIDTH = 64
local ROW_TEXT_LEFT = 94
local SCROLLBAR_THICKNESS = 3
local TAB_CAP_WIDTH = 5
local TAB_GAP = 4
local TAB_HEIGHT = 50
local TAB_INSET = 8
local TAB_TEXT_INSET = 10
local TAB_TEXT_TOP = 14
local TOP_BAR_HEIGHT = 78

local DETAIL_LEFT = LIST_WIDTH + LEFT_LINE_WIDTH + DETAIL_INSET
local LIST_TOP = TOP_BAR_HEIGHT + LIST_FRAME_TOP_HEIGHT + 4

local STYLES = {
    body = "PDAQuestDetails",
    hint = "PDAQuestDetailsRegion",
    rowName = "PDAQuestSlotName",
    rowSubtitle = "PDAQuestDetailsRegion",
    status = "PDAQuestSlotName",
    tab = "PDACurrQuestBtn",
    tabIdle = "PDAQuestDetails",
    title = "PDAQuestDetailsNameMain",
}

local TEXTURE_ROOT = "/Game/GameLite/FPS_Game/UIRemaster/UITextures/PDA/"

local TEXTURES = {
    buttonSide = "Journal/T_button_side",
    divider = "Journal/T_turial_dieline",
    frameBottom = "PDAView/QuestBackground/T_pda_questframe_bot",
    frameMiddle = "PDAView/QuestBackground/T_pda_questframe_tileing",
    frameTop = "PDAView/QuestBackground/T_pda_questframe_top",
    leftLine = "PDAView/Frame/MidleFrame/T_pda_decorleftline_tileing",
    rowSelected = "Journal/T_quest_scroll_hover",
}

-- UMG tints are linear FLinearColor; hex values are sRGB, as sampled from the vanilla PDA.
local function color(hex, alpha)
    local function channel(offset)
        local srgb = tonumber(hex:sub(offset, offset + 1), 16) / 255

        if srgb <= 0.04045 then
            return srgb / 12.92
        end

        return ((srgb + 0.055) / 1.055) ^ 2.4
    end

    return { A = alpha or 1, B = channel(5), G = channel(3), R = channel(1) }
end

-- Tab tints are W_PDAUpgradesButton's ButtonCollorEnable/ButtonCollorDisable; the scrollbar
-- is W_PDANotesDetails' TextScroll thumb. Badges are white masks, tinted like selected tabs.
local COLORS = {
    badge = color("CABFB0"),
    clear = color("000000", 0),
    detailShade = color("141210"),
    hintBar = color("131211", 0.85),
    hover = color("000000", 0.6),
    iconBox = color("131211", 0.7),
    rowSelected = color("EF8E02", 0.9),
    rowSelectedPlain = color("EF8E02", 0.4),
    scrollThumb = color("C1B7A8", 0.5),
    scrollThumbActive = color("C1B7A8"),
    scrollTrack = color("C1B7A8", 0.12),
    tab = color("232120"),
    tabSelected = color("CABFB0"),
    topBar = color("131211"),
    white = color("FFFFFF"),
}

-- One widget set per UE4SS mod Lua state; it exists only while the Archive tab is claimed.
local parts
local shown = {}

local function texturePath(relative)
    local name = relative:match("([^/]+)$")
    return TEXTURE_ROOT .. relative .. "." .. name
end

local function padding(left, top, right, bottom)
    return { Bottom = bottom or 0, Left = left or 0, Right = right or 0, Top = top or 0 }
end

-- Every created widget, so list membership doubles as the liveness and cleanup set.
local function track(widget)
    parts.all[#parts.all + 1] = widget
    return widget
end

-- The given widgets in order, skipping missing ones.
local function present(...)
    local widgets = {}

    for index = 1, select("#", ...) do
        local widget = select(index, ...)

        if widget then
            widgets[#widgets + 1] = widget
        end
    end

    return widgets
end

local function place(widget, horizontal, vertical, slotPadding)
    if not widget then
        return nil
    end

    local slot = parts.root:AddChildToOverlay(widget)

    slot:SetHorizontalAlignment(horizontal)
    slot:SetVerticalAlignment(vertical)
    slot:SetPadding(slotPadding)
    return slot
end

local function setOnce(key, value, apply)
    if shown[key] ~= value then
        apply(value)
        shown[key] = value
    end
end

local function setText(key, widget, text)
    setOnce(key .. ".text", text or "", function(value)
        widget:SetText(FText(value))
    end)
end

local function setVisible(key, widget, visible, visibleState)
    setOnce(key .. ".visible", visible, function(value)
        widget:SetVisibility(value and (visibleState or VISIBILITY_HIT_TEST_INVISIBLE) or VISIBILITY_COLLAPSED)
    end)
end

local function setColor(key, image, tint)
    setOnce(key .. ".color", string.format("%.3f,%.3f,%.3f,%.3f", tint.R, tint.G, tint.B, tint.A), function()
        image:SetColorAndOpacity(tint)
    end)
end

-- The game's UImage has no SetBrushSize, and DesiredSizeOverride set before parenting is lost,
-- so the brush's stored ImageSize is written directly. Sizing never aborts the page.
local function setImageSize(imageWidget, width, height)
    local size = { X = width or 0, Y = height or 0 }
    local ok, errorMessage = pcall(function()
        imageWidget.Brush.ImageSize = size
    end)

    if not ok and not parts.sizeWarned then
        parts.sizeWarned = true
        Unreal.log("Archive image size not applied (" .. tostring(errorMessage) .. "); images may draw at 32x32")
    end

    pcall(function()
        imageWidget:SetDesiredSizeOverride(size)
    end)
end

local function setPadding(key, slot, slotPadding)
    local text = string.format("%g,%g,%g,%g", slotPadding.Left, slotPadding.Top, slotPadding.Right, slotPadding.Bottom)

    setOnce(key .. ".padding", text, function()
        slot:SetPadding(slotPadding)
    end)
end

-- Images are decoration; without them the page still works as styled text. A textured image
-- whose texture is missing is skipped, unless it has a solid fallback tint.
local function image(tint, texture, width, height, fallbackTint)
    if not parts.imagesAvailable then
        return nil
    end

    local loaded = texture and Unreal.loadTexture(texturePath(texture))

    if texture and not loaded then
        if not fallbackTint then
            return nil
        end

        tint = fallbackTint
    end

    local ok, result = pcall(Unreal.createImage, parts.outer)

    if not ok then
        parts.imagesAvailable = false
        Unreal.log("Archive images unavailable (" .. tostring(result) .. "); showing text only")
        return nil
    end

    if loaded then
        result:SetBrushResourceObject(loaded)
    end

    result:SetColorAndOpacity(tint)
    setImageSize(result, width, height)
    result:SetVisibility(VISIBILITY_HIT_TEST_INVISIBLE)
    return track(result)
end

local function text(styleId)
    local widget, styled = Unreal.createStyledText(parts.controller, styleId)

    if not styled and not parts.styleWarned then
        parts.styleWarned = true
        Unreal.log("game font style '" .. styleId .. "' not applied; Archive text may use the default look")
    end

    widget:SetVisibility(VISIBILITY_HIT_TEST_INVISIBLE)
    return track(widget)
end

-- Category widths follow title length so long titles fit at the button font size.
local function tabWidths(titles)
    local available = LIST_WIDTH - 2 * TAB_INSET - TAB_GAP * (#titles - 1)
    local weights, total = {}, 0

    for index, title in ipairs(titles) do
        weights[index] = (utf8.len(title) or #title) + 4
        total = total + weights[index]
    end

    local widths = {}

    for index, weight in ipairs(weights) do
        widths[index] = math.floor(available * weight / total)
    end

    return widths
end

local function buildFrame()
    place(image(COLORS.topBar, nil, LIST_WIDTH, TOP_BAR_HEIGHT), ALIGN_LEFT, ALIGN_TOP, padding())
    place(
        image(COLORS.white, TEXTURES.frameTop, LIST_WIDTH, LIST_FRAME_TOP_HEIGHT),
        ALIGN_LEFT,
        ALIGN_TOP,
        padding(0, TOP_BAR_HEIGHT)
    )
    place(
        image(COLORS.white, TEXTURES.frameMiddle, LIST_WIDTH, 0),
        ALIGN_LEFT,
        ALIGN_FILL,
        padding(0, TOP_BAR_HEIGHT + LIST_FRAME_TOP_HEIGHT, 0, HINT_BAR_HEIGHT + LIST_FRAME_BOTTOM_HEIGHT)
    )
    place(
        image(COLORS.white, TEXTURES.frameBottom, LIST_WIDTH, LIST_FRAME_BOTTOM_HEIGHT),
        ALIGN_LEFT,
        ALIGN_BOTTOM,
        padding(0, 0, 0, HINT_BAR_HEIGHT)
    )
    place(
        image(COLORS.white, TEXTURES.leftLine, LEFT_LINE_WIDTH, 0),
        ALIGN_LEFT,
        ALIGN_FILL,
        padding(LIST_WIDTH, 0, 0, HINT_BAR_HEIGHT)
    )
    place(image(COLORS.detailShade), ALIGN_FILL, ALIGN_FILL, padding(LIST_WIDTH + LEFT_LINE_WIDTH, 0, 0, HINT_BAR_HEIGHT))
    place(image(COLORS.hintBar, nil, 0, HINT_BAR_HEIGHT), ALIGN_FILL, ALIGN_BOTTOM, padding())
end

-- A label centred in a box, as W_PDAUpgradesButton centres its text; falls back to a fixed
-- inset from the box's left edge if a SizeBox can't be made.
local function placeCentered(label, left, top, width, height)
    local ok, sizeBox = pcall(Unreal.createWidget, Unreal.SIZE_BOX_CLASS, parts.outer)

    if not ok then
        if not parts.centerWarned then
            parts.centerWarned = true
            Unreal.log("centred labels unavailable (" .. tostring(sizeBox) .. "); tab text is left-aligned")
        end

        place(label, ALIGN_LEFT, ALIGN_TOP, padding(left + TAB_TEXT_INSET, top + TAB_TEXT_TOP))
        return
    end

    track(sizeBox)
    sizeBox:SetWidthOverride(width)
    sizeBox:SetHeightOverride(height)

    local slot = sizeBox:AddChild(label)

    slot:SetHorizontalAlignment(ALIGN_CENTER)
    slot:SetVerticalAlignment(ALIGN_CENTER)
    sizeBox:SetVisibility(VISIBILITY_SELF_HIT_TEST_INVISIBLE)
    place(sizeBox, ALIGN_LEFT, ALIGN_TOP, padding(left, top))
end

-- Category buttons are built like W_PDAUpgradesButton: a tinted middle between two rounded
-- T_button_side caps, the right one mirrored, with the label centred over all three.
local function buildTabs(titles)
    local left = TAB_INSET
    local top = (TOP_BAR_HEIGHT - TAB_HEIGHT) / 2

    for index, width in ipairs(tabWidths(titles)) do
        local middleWidth = width - 2 * TAB_CAP_WIDTH
        local leftCap = image(COLORS.tab, TEXTURES.buttonSide, TAB_CAP_WIDTH, TAB_HEIGHT, COLORS.tab)
        local background = image(COLORS.tab, nil, middleWidth, TAB_HEIGHT)
        local rightCap = image(COLORS.tab, TEXTURES.buttonSide, TAB_CAP_WIDTH, TAB_HEIGHT, COLORS.tab)
        -- Font styles fix the text colour, so the dark selected and light idle looks are two labels.
        local label = text(STYLES.tab)
        local idleLabel = text(STYLES.tabIdle)

        place(leftCap, ALIGN_LEFT, ALIGN_TOP, padding(left, top))
        place(background, ALIGN_LEFT, ALIGN_TOP, padding(left + TAB_CAP_WIDTH, top))
        place(rightCap, ALIGN_LEFT, ALIGN_TOP, padding(left + TAB_CAP_WIDTH + middleWidth, top))

        if rightCap then
            pcall(function()
                rightCap:SetRenderScale({ X = -1, Y = 1 })
            end)
        end

        label:SetText(FText(titles[index]))
        idleLabel:SetText(FText(titles[index]))
        placeCentered(label, left, top, width, TAB_HEIGHT)
        placeCentered(idleLabel, left, top, width, TAB_HEIGHT)

        -- The middle is the click target; without images the labels take clicks instead.
        if background then
            background:SetVisibility(VISIBILITY_VISIBLE)
        end

        parts.tabs[index] = {
            background = background,
            caps = present(leftCap, rightCap),
            hits = present(background, label, idleLabel),
            idleLabel = idleLabel,
            label = label,
            labelState = background and VISIBILITY_HIT_TEST_INVISIBLE or VISIBILITY_VISIBLE,
        }
        left = left + width + TAB_GAP
    end
end

-- A hidden ScrollBox that catches the wheel natively. Sized by a SizeBox: a fixed box, or with
-- no height, capped at 1 so the tall scroll content can't grow the page while a fill slot
-- stretches it. It is also Slate-hoverable, so a row's catcher doubles as its click target.
local function wheelCatcher(vertical, slotPadding, width, height)
    local sizeBox = track(Unreal.createWidget(Unreal.SIZE_BOX_CLASS, parts.outer))
    local scrollBox = track(Unreal.createWidget(Unreal.SCROLL_BOX_CLASS, parts.outer))
    local spacer = track(Unreal.createWidget(Unreal.SPACER_CLASS, parts.outer))

    for property, value in pairs({ AllowOverscroll = false, bAnimateWheelScrolling = false, ConsumeMouseWheel = CONSUME_WHEEL_ALWAYS }) do
        pcall(function()
            scrollBox[property] = value
        end)
    end

    pcall(function()
        scrollBox:SetScrollBarVisibility(VISIBILITY_COLLAPSED)
    end)

    spacer:SetSize({ X = 1, Y = WHEEL_CONTENT_HEIGHT })
    spacer:SetVisibility(VISIBILITY_HIT_TEST_INVISIBLE)
    scrollBox:AddChild(spacer)
    scrollBox:SetVisibility(VISIBILITY_VISIBLE)

    if height then
        sizeBox:SetHeightOverride(height)
    else
        sizeBox:SetMaxDesiredHeight(1)
    end

    if width then
        sizeBox:SetWidthOverride(width)
    end

    sizeBox:AddChild(scrollBox)
    sizeBox:SetVisibility(VISIBILITY_SELF_HIT_TEST_INVISIBLE)
    place(sizeBox, width and ALIGN_LEFT or ALIGN_FILL, vertical, slotPadding)
    scrollBox:SetScrollOffset(WHEEL_CENTER)
    return scrollBox, sizeBox
end

-- Without catchers the page still works: clicks go to the row images, scrolling to the keyboard.
local function tryWheelCatcher(...)
    if not parts.wheelAvailable then
        return nil
    end

    local ok, result, sizeBox = pcall(wheelCatcher, ...)

    if ok then
        return result, sizeBox
    end

    parts.wheelAvailable = false
    Unreal.log("mouse wheel unavailable (" .. tostring(result) .. "); use PgUp/PgDn and [ ]")
end

local function buildRows(rowCount)
    for index = 1, rowCount do
        local top = LIST_TOP + (index - 1) * ROW_HEIGHT
        local row = {}

        row.hover = image(COLORS.clear, nil, LIST_WIDTH, ROW_HEIGHT)
        row.selected = image(COLORS.rowSelected, TEXTURES.rowSelected, LIST_WIDTH, ROW_HEIGHT, COLORS.rowSelectedPlain)
        row.icon = image(COLORS.white, nil, ROW_ICON_WIDTH, ROW_ICON_HEIGHT)
        row.name = text(STYLES.rowName)
        row.subtitle = text(STYLES.rowSubtitle)

        if row.hover then
            place(row.hover, ALIGN_LEFT, ALIGN_TOP, padding(0, top))
        end

        if row.selected then
            place(row.selected, ALIGN_LEFT, ALIGN_TOP, padding(0, top))
        end

        if row.icon then
            row.iconSlot = place(row.icon, ALIGN_LEFT, ALIGN_TOP, padding(ROW_ICON_LEFT, top))
            row.icon:SetVisibility(VISIBILITY_COLLAPSED)
        end

        place(row.name, ALIGN_LEFT, ALIGN_TOP, padding(ROW_TEXT_LEFT, top + 4))
        place(row.subtitle, ALIGN_LEFT, ALIGN_TOP, padding(ROW_TEXT_LEFT, top + 38))

        -- The topmost hit-testable widget takes the row's hover, clicks and wheel. Slate marks
        -- the whole hit path hovered, so the catcher's SizeBox and the row image are checked too.
        row.wheel, row.wheelBox = tryWheelCatcher(ALIGN_TOP, padding(0, top), LIST_WIDTH, ROW_HEIGHT)

        if not row.wheel then
            local fallback = row.hover or row.name

            fallback:SetVisibility(VISIBILITY_VISIBLE)
        end

        row.hits = present(row.wheel, row.wheelBox, row.hover, row.name)

        row.top = top
        parts.rows[index] = row
    end
end

-- Struct properties only take field-by-field writes; assigning a Lua table over one no-ops.
local function setLinearColor(target, tint)
    target.R, target.G, target.B, target.A = tint.R, tint.G, tint.B, tint.A
end

-- W_PDANotesDetails' TextScroll look: a 3-unit flat thumb over a faint track, no edge shadows.
-- Best effort; a failure leaves the engine's default bar, which still scrolls.
local function styleScrollBar(scrollBox)
    local ok, errorMessage = pcall(function()
        scrollBox:SetScrollbarThickness({ X = SCROLLBAR_THICKNESS, Y = SCROLLBAR_THICKNESS })

        local barStyle = scrollBox.WidgetBarStyle
        local thumbTints = {
            DraggedThumbImage = COLORS.scrollThumbActive,
            HoveredThumbImage = COLORS.scrollThumbActive,
            NormalThumbImage = COLORS.scrollThumb,
            VerticalBackgroundImage = COLORS.scrollTrack,
        }

        -- An Image brush with no texture draws as a flat tinted quad.
        for brushName, tint in pairs(thumbTints) do
            local brush = barStyle[brushName]

            brush.DrawAs = BRUSH_DRAW_IMAGE
            setLinearColor(brush.TintColor.SpecifiedColor, tint)
        end

        scrollBox.WidgetStyle.TopShadowBrush.DrawAs = BRUSH_DRAW_NONE
        scrollBox.WidgetStyle.BottomShadowBrush.DrawAs = BRUSH_DRAW_NONE
    end)

    if not ok then
        Unreal.log("detail scrollbar style not applied (" .. tostring(errorMessage) .. "); using the default bar")
    end
end

-- The body text in a real ScrollBox, as W_PDANotesDetails scrolls its notes: the wheel scrolls
-- it natively and a thin bar shows when the text overflows. A fixed-width SizeBox sets the
-- text column, so wrapping never depends on the page's width.
local function buildDetailScroll(body)
    local sizeBox = Unreal.createWidget(Unreal.SIZE_BOX_CLASS, parts.outer)
    local scrollBox = Unreal.createWidget(Unreal.SCROLL_BOX_CLASS, parts.outer)

    for property, value in pairs({ AllowOverscroll = false, ConsumeMouseWheel = CONSUME_WHEEL_ALWAYS }) do
        pcall(function()
            scrollBox[property] = value
        end)
    end

    styleScrollBar(scrollBox)
    scrollBox:AddChild(body)
    scrollBox:SetVisibility(VISIBILITY_VISIBLE)
    sizeBox:SetWidthOverride(DETAIL_TEXT_WIDTH)
    -- As with the wheel catchers: the fill slot sets the height, so long text can't grow the page.
    sizeBox:SetMaxDesiredHeight(1)
    sizeBox:AddChild(scrollBox)
    sizeBox:SetVisibility(VISIBILITY_SELF_HIT_TEST_INVISIBLE)
    track(sizeBox)
    track(scrollBox)
    return scrollBox, place(sizeBox, ALIGN_LEFT, ALIGN_FILL, padding(DETAIL_LEFT, 0, 0, HINT_BAR_HEIGHT + 10))
end

local function buildDetail()
    local detail = {}

    detail.iconBox = image(COLORS.iconBox, nil, DETAIL_ICON_SIZE, DETAIL_ICON_SIZE)
    detail.icon = image(COLORS.white, nil, DETAIL_ICON_SIZE, DETAIL_ICON_SIZE)
    detail.title = text(STYLES.title)
    detail.subtitle = text(STYLES.hint)
    detail.divider = image(COLORS.white, TEXTURES.divider, 0, DIVIDER_HEIGHT)
    detail.picture = image(COLORS.white, nil, DETAIL_IMAGE_WIDTH, DETAIL_IMAGE_HEIGHT)
    detail.body = text(STYLES.body)

    if detail.iconBox then
        place(detail.iconBox, ALIGN_LEFT, ALIGN_TOP, padding(DETAIL_LEFT, DETAIL_TOP))
        detail.iconSlot = place(detail.icon, ALIGN_LEFT, ALIGN_TOP, padding(DETAIL_LEFT, DETAIL_TOP))
        detail.iconBox:SetVisibility(VISIBILITY_COLLAPSED)
        detail.icon:SetVisibility(VISIBILITY_COLLAPSED)
    end

    detail.titleSlot = place(detail.title, ALIGN_LEFT, ALIGN_TOP, padding(DETAIL_LEFT, DETAIL_TOP))
    detail.subtitleSlot = place(detail.subtitle, ALIGN_LEFT, ALIGN_TOP, padding(DETAIL_LEFT, DETAIL_TOP + 44))

    if detail.divider then
        detail.dividerSlot = place(detail.divider, ALIGN_FILL, ALIGN_TOP, padding(DETAIL_LEFT, 0, DETAIL_INSET))
    end

    -- Beside the text column, like the Notes page's picture; past a narrow page it clips, not overlaps.
    if detail.picture then
        detail.pictureSlot = place(detail.picture, ALIGN_LEFT, ALIGN_TOP, padding(DETAIL_LEFT + DETAIL_TEXT_WIDTH + DETAIL_IMAGE_GAP))
        detail.picture:SetVisibility(VISIBILITY_COLLAPSED)
    end

    -- The generated text is pre-wrapped; auto-wrap only catches lines wider than the column.
    pcall(function()
        detail.body.CommonTextObj:SetAutoWrapText(true)
        detail.body:SetClipping(1)
    end)

    local ok, scrollBox, scrollSlot = pcall(buildDetailScroll, detail.body)

    if ok then
        detail.scroll, detail.bodySlot = scrollBox, scrollSlot
    else
        -- Without a ScrollBox, main.lua pages the body by line instead.
        Unreal.log("detail scroll panel unavailable (" .. tostring(scrollBox) .. "); [ ] page the details")
        detail.bodySlot = place(detail.body, ALIGN_LEFT, ALIGN_FILL, padding(DETAIL_LEFT, 0, 0, HINT_BAR_HEIGHT + 10))
    end

    parts.detail = detail
end

local function buildHintBar()
    parts.status = text(STYLES.status)
    parts.controls = text(STYLES.hint)
    place(parts.status, ALIGN_LEFT, ALIGN_BOTTOM, padding(15, 0, 0, 26))
    place(parts.controls, ALIGN_RIGHT, ALIGN_BOTTOM, padding(0, 0, 15, 30))
end

-- Scales a texture to fit a box, centered, keeping its aspect ratio. Mask textures take a tint.
local function showIcon(key, iconImage, slot, path, left, top, width, height, tint)
    local texture = path ~= "" and Unreal.loadTexture(path) or nil

    setVisible(key, iconImage, texture ~= nil)

    if not texture then
        return
    end

    setColor(key, iconImage, tint or COLORS.white)
    setOnce(key .. ".texture", string.format("%s@%g,%g", path, left, top), function()
        local textureWidth, textureHeight = Unreal.textureSize(texture)
        local scale = math.min(width / textureWidth, height / textureHeight)
        local shownWidth, shownHeight = textureWidth * scale, textureHeight * scale

        iconImage:SetBrushResourceObject(texture)
        setImageSize(iconImage, shownWidth, shownHeight)
        slot:SetPadding(padding(left + (width - shownWidth) / 2, top + (height - shownHeight) / 2))
    end)
end

function ArchivePage.hide()
    if parts then
        for index, widget in ipairs(parts.all) do
            local ok, errorMessage = pcall(function()
                if Unreal.isValid(widget) then
                    widget:RemoveFromParent()
                end
            end)

            if not ok then
                Unreal.log("Archive cleanup failed for widget " .. index .. ": " .. tostring(errorMessage))
            end
        end
    end

    parts, shown = nil, {}
end

function ArchivePage.isShown()
    return parts ~= nil
end

function ArchivePage.isAlive()
    if not parts then
        return false
    end

    for _, widget in ipairs(parts.all) do
        if not Unreal.isValid(widget) then
            return false
        end
    end

    return true
end

---@param archive { page: any, root: any }
---@param options { rows: integer, tabTitles: string[] }
function ArchivePage.show(archive, controller, options)
    ArchivePage.hide()

    local ok, errorMessage = pcall(function()
        parts = {
            all = {},
            controller = controller,
            imagesAvailable = true,
            outer = archive.page.WidgetTree,
            root = archive.root,
            rows = {},
            tabs = {},
            wheelAvailable = true,
        }
        buildFrame()
        buildTabs(options.tabTitles)
        buildRows(options.rows)
        buildDetail()
        buildHintBar()
    end)

    if not ok then
        ArchivePage.hide()
        error("Archive page creation failed: " .. tostring(errorMessage), 0)
    end
end

---@class ZoneCodexPageContent
---@field controls string
---@field detail { body: string, icon: string, image: string, key: string, subtitle: string, title: string }
---@field maskIcons boolean Icons are white masks (faction badges) that need a tint.
---@field rows (ZoneCodexRow|false)[]
---@field selectedTab integer
---@field status string

---@param content ZoneCodexPageContent
function ArchivePage.setContent(content)
    if not parts then
        return
    end

    for index, tab in ipairs(parts.tabs) do
        local selected = index == content.selectedTab
        local key = "tab" .. index

        if tab.background then
            setColor(key, tab.background, selected and COLORS.tabSelected or COLORS.tab)
        end

        for capIndex, cap in ipairs(tab.caps) do
            setColor(key .. ".cap" .. capIndex, cap, selected and COLORS.tabSelected or COLORS.tab)
        end

        setVisible(key .. ".label", tab.label, selected, tab.labelState)
        setVisible(key .. ".idleLabel", tab.idleLabel, not selected, tab.labelState)
    end

    local iconTint = content.maskIcons and COLORS.badge or COLORS.white

    for index, row in ipairs(parts.rows) do
        local item = content.rows[index]
        local key = "row" .. index

        row.filled = item and true or false
        setText(key .. ".name", row.name, item and item.name or "")
        setText(key .. ".subtitle", row.subtitle, item and item.subtitle or "")

        if row.selected then
            setVisible(key .. ".selected", row.selected, item and item.selected or false)
        end

        if row.icon then
            local path = item and item.icon or ""
            local iconTop = row.top + (ROW_HEIGHT - ROW_ICON_HEIGHT) / 2

            showIcon(key .. ".icon", row.icon, row.iconSlot, path, ROW_ICON_LEFT, iconTop, ROW_ICON_WIDTH, ROW_ICON_HEIGHT, iconTint)
        end
    end

    local detail = parts.detail
    local hasIcon = false

    if detail.icon then
        showIcon("detail.icon", detail.icon, detail.iconSlot, content.detail.icon, DETAIL_LEFT, DETAIL_TOP, DETAIL_ICON_SIZE, DETAIL_ICON_SIZE, iconTint)
        hasIcon = shown["detail.icon.visible"] == true
        setVisible("detail.iconBox", detail.iconBox, hasIcon)
    end

    -- Entries without an icon pull the title left and the body up.
    local titleLeft = hasIcon and DETAIL_LEFT + DETAIL_ICON_SIZE + 24 or DETAIL_LEFT
    local headerBottom = DETAIL_TOP + (hasIcon and DETAIL_ICON_SIZE or 72) + 12
    local bodyTop = headerBottom + DIVIDER_HEIGHT + 14

    setPadding("detail.title", detail.titleSlot, padding(titleLeft, DETAIL_TOP + (hasIcon and 30 or 0)))
    setPadding("detail.subtitle", detail.subtitleSlot, padding(titleLeft, DETAIL_TOP + (hasIcon and 74 or 44)))

    if detail.dividerSlot then
        setPadding("detail.divider", detail.dividerSlot, padding(DETAIL_LEFT, headerBottom, DETAIL_INSET))
    end

    if detail.picture then
        local pictureLeft = DETAIL_LEFT + DETAIL_TEXT_WIDTH + DETAIL_IMAGE_GAP

        showIcon("detail.picture", detail.picture, detail.pictureSlot, content.detail.image, pictureLeft, bodyTop, DETAIL_IMAGE_WIDTH, DETAIL_IMAGE_HEIGHT)
    end

    setPadding("detail.body", detail.bodySlot, padding(DETAIL_LEFT, bodyTop, 0, HINT_BAR_HEIGHT + 10))
    setText("detail.title", detail.title, content.detail.title)
    setText("detail.subtitle", detail.subtitle, content.detail.subtitle)
    setText("detail.body", detail.body, content.detail.body)

    -- A new entry starts at the top; count refreshes of the same entry keep the reader's place.
    if detail.scroll then
        setOnce("detail.key", content.detail.key, function()
            pcall(function()
                detail.scroll:ScrollToStart()
            end)
        end)
    end

    setText("status", parts.status, content.status)
    setText("controls", parts.controls, content.controls)
end

---@return boolean scrollable Whether the detail body sits in a real scroll panel.
function ArchivePage.hasDetailScroll()
    return parts ~= nil and parts.detail.scroll ~= nil
end

-- Scrolls the detail panel by a step, as [ and ] do; false when there's no panel to scroll.
---@param direction integer 1 down, -1 up.
---@return boolean
function ArchivePage.scrollDetail(direction)
    if not ArchivePage.hasDetailScroll() then
        return false
    end

    local scrollBox = parts.detail.scroll
    local ok, errorMessage = pcall(function()
        local endOffset = scrollBox:GetScrollOffsetOfEnd()
        local offset = scrollBox:GetScrollOffset() + direction * DETAIL_SCROLL_STEP

        scrollBox:SetScrollOffset(math.max(0, math.min(endOffset, offset)))
    end)

    if not ok and not parts.scrollWarned then
        parts.scrollWarned = true
        Unreal.log("detail keyboard scroll failed (" .. tostring(errorMessage) .. "); the wheel still scrolls")
    end

    return true
end

local function isHovered(widget)
    local ok, hovered = pcall(function()
        return widget:IsHovered()
    end)

    return ok and hovered == true
end

-- Slate hover only: UE4SS can't pass FGeometry to IsUnderLocation, so a geometry hit test
-- never matched in game.
---@return "tab"|"row"|nil kind
---@return integer|nil index
function ArchivePage.hovered()
    if not parts then
        return nil
    end

    for _, kind in ipairs({ "tab", "row" }) do
        for index, item in ipairs(parts[kind .. "s"]) do
            for _, widget in ipairs(item.hits) do
                if isHovered(widget) then
                    return kind, index
                end
            end
        end
    end

    return nil
end

local function hoverFlags(items, field)
    local flags = {}

    for index, item in ipairs(items) do
        flags[index] = item[field] and (isHovered(item[field]) and "1" or "0") or "-"
    end

    return table.concat(flags)
end

-- Which page widgets Slate reports as hovered, one flag per tab or row ("-" when absent),
-- so a missed click shows whether hover reaches the page at all.
---@return string
function ArchivePage.hoverReport()
    if not parts then
        return "no page"
    end

    return string.format(
        "root=%s detail=%s tabs=%s rowWheels=%s rowBoxes=%s rowImages=%s",
        isHovered(parts.root) and "1" or "0",
        parts.detail.scroll and (isHovered(parts.detail.scroll) and "1" or "0") or "-",
        hoverFlags(parts.tabs, "background"),
        hoverFlags(parts.rows, "wheel"),
        hoverFlags(parts.rows, "wheelBox"),
        hoverFlags(parts.rows, "hover")
    )
end

-- A click is handled on the poll after the press, so the target hovered on the previous poll
-- (at most one poll old) catches presses that already changed the hover state.
---@return "tab"|"row"|nil kind
---@return integer|nil index
---@return { X: number, Y: number }|nil mouse The cursor, for diagnosing a missed click.
function ArchivePage.clickTarget()
    if not parts then
        return nil
    end

    local kind, index = ArchivePage.hovered()

    if kind then
        return kind, index
    end

    if parts.lastHover then
        return parts.lastHover.kind, parts.lastHover.index
    end

    return nil, nil, Unreal.mousePosition()
end

local function wheelNotches(scrollBox)
    if not scrollBox then
        return 0
    end

    local ok, offset = pcall(function()
        return scrollBox:GetScrollOffset()
    end)

    if not ok or type(offset) ~= "number" then
        return 0
    end

    local delta = offset - WHEEL_CENTER

    if math.abs(delta) < 1 then
        return 0
    end

    pcall(function()
        scrollBox:SetScrollOffset(WHEEL_CENTER)
    end)

    if math.abs(delta) > WHEEL_MAX_DELTA then
        return 0
    end

    local notches = math.max(1, math.floor(math.abs(delta) / WHEEL_NOTCH + 0.5))

    return delta > 0 and notches or -notches
end

-- List wheel notches since the last call, positive for down, then re-arms the catchers. The
-- detail panel scrolls itself natively.
---@return integer listNotches
function ArchivePage.takeWheel()
    if not parts then
        return 0
    end

    local listNotches = 0

    for _, row in ipairs(parts.rows) do
        listNotches = listNotches + wheelNotches(row.wheel)
    end

    return listNotches
end

-- Called while the Archive tab is hidden, so a stale hover can't catch a later click.
function ArchivePage.forgetHover()
    if parts then
        parts.lastHover = nil
    end
end

-- Darkens the row under the mouse, like the vanilla list; polled because UMG events need Blueprint.
function ArchivePage.updateHover()
    if not parts then
        return
    end

    local kind, index = ArchivePage.hovered()

    parts.lastHover = kind and { index = index, kind = kind } or nil

    for rowIndex, row in ipairs(parts.rows) do
        if row.hover then
            local hovered = kind == "row" and rowIndex == index and row.filled == true
            setColor("row" .. rowIndex .. ".hover", row.hover, hovered and COLORS.hover or COLORS.clear)
        end
    end
end

return ArchivePage
