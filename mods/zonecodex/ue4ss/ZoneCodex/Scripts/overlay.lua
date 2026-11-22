-- The Ctrl+E fallback: plain text widgets (header, tab sidebar, entry rows, detail) in the
-- viewport, used when the PDA's Archive tab is taken or disabled. Game thread only.
local Unreal = require("unreal")

local Overlay = {}

local GUTTER = 24
local LIST_WIDTH = 400
local MAX_WIDTH = 1400
local TAB_WIDTH = 220
local VISIBILITY_HIT_TEST_INVISIBLE = 4
local Z_ORDER = 1000

local COLORS = {
    detail = { R = 0.92, G = 0.92, B = 0.88, A = 1 },
    header = { R = 1, G = 0.72, B = 0.1, A = 1 },
    row = { R = 0.85, G = 0.85, B = 0.8, A = 1 },
    tab = { R = 1, G = 0.72, B = 0.1, A = 1 },
}

-- One widget set per UE4SS mod Lua state; it exists only while the fallback is open.
local shownTexts = {}
local widgets

local function styleText(widget, color)
    local text = widget.CommonTextObj
    assert(Unreal.isValid(text), "codex text block unavailable")
    text:SetJustification(0)
    text:SetAutoWrapText(false)
    text:SetColorAndOpacity({ SpecifiedColor = color, ColorUseRule = 0 })
    text:SetShadowOffset({ X = 1, Y = 1 })
    text:SetShadowColorAndOpacity({ R = 0, G = 0, B = 0, A = 0.9 })
end

local function eachWidget(callback)
    if not widgets then
        return
    end

    callback("header", widgets.header)
    callback("detail", widgets.detail)

    for index, widget in ipairs(widgets.tabs) do
        callback("tab" .. index, widget)
    end

    for index, widget in ipairs(widgets.rows) do
        callback("row" .. index, widget)
    end
end

function Overlay.hide()
    eachWidget(function(name, widget)
        local ok, errorMessage = pcall(function()
            if Unreal.isValid(widget) then
                widget:RemoveFromParent()
            end
        end)

        if not ok then
            Unreal.log("overlay cleanup failed for " .. name .. ": " .. tostring(errorMessage))
        end
    end)

    shownTexts, widgets = {}, nil
end

function Overlay.isAlive()
    if not widgets then
        return false
    end

    local alive = true

    eachWidget(function(_, widget)
        alive = alive and Unreal.isValid(widget)
    end)

    return alive
end

function Overlay.isShown()
    return widgets ~= nil
end

---@param options { lineHeight: number, tabCount: integer, visibleRows: integer }
function Overlay.show(controller, options)
    Overlay.hide()

    local function create(color)
        local widget = Unreal.createTextWidget(controller)
        -- The fallback never takes clicks, so it can't block the PDA underneath.
        widget:SetVisibility(VISIBILITY_HIT_TEST_INVISIBLE)
        styleText(widget, color)
        return widget
    end

    local function place(widget, positionX, positionY, width, height)
        widget:AddToViewport(Z_ORDER)
        widget:SetDesiredSizeInViewport({ X = width, Y = height })
        -- Nonzero viewport anchors read back as zero in this game; position from the top left.
        widget:SetAnchorsInViewport({ Minimum = { X = 0, Y = 0 }, Maximum = { X = 0, Y = 0 } })
        widget:SetAlignmentInViewport({ X = 0, Y = 0 })
        widget:SetPositionInViewport({ X = positionX, Y = positionY }, false)
    end

    local ok, errorMessage = pcall(function()
        widgets = { rows = {}, tabs = {} }
        widgets.header = create(COLORS.header)
        widgets.detail = create(COLORS.detail)

        for index = 1, options.tabCount do
            widgets.tabs[index] = create(COLORS.tab)
        end

        for index = 1, options.visibleRows do
            widgets.rows[index] = create(COLORS.row)
        end

        local lineHeight = options.lineHeight
        local width, height = Unreal.viewportSize(controller)
        local boxHeight = (2 + options.visibleRows) * lineHeight + GUTTER
        local boxWidth = math.min(MAX_WIDTH, width - 128)
        local left = (width - boxWidth) / 2
        local top = math.max(32, (height - boxHeight) / 2)

        local paneTop = top + 2 * lineHeight + GUTTER
        local listLeft = left + TAB_WIDTH + GUTTER
        local detailLeft = listLeft + LIST_WIDTH + GUTTER
        local paneHeight = options.visibleRows * lineHeight

        place(widgets.header, left, top, boxWidth, 2 * lineHeight)

        for index, widget in ipairs(widgets.tabs) do
            place(widget, left, paneTop + (index - 1) * lineHeight, TAB_WIDTH, lineHeight)
        end

        for index, widget in ipairs(widgets.rows) do
            place(widget, listLeft, paneTop + (index - 1) * lineHeight, LIST_WIDTH, lineHeight)
        end

        place(widgets.detail, detailLeft, paneTop, math.max(GUTTER, left + boxWidth - detailLeft), paneHeight)
    end)

    if not ok then
        Overlay.hide()
        error("overlay creation failed: " .. tostring(errorMessage), 0)
    end
end

---@param texts { detail: string, header: string, rows: string[], tabs: string[] }
function Overlay.setTexts(texts)
    local function set(name, widget, text)
        text = text or ""

        if shownTexts[name] ~= text then
            widget:SetText(FText(text))
            shownTexts[name] = text
        end
    end

    if not widgets then
        return
    end

    set("header", widgets.header, texts.header)
    set("detail", widgets.detail, texts.detail)

    for index, widget in ipairs(widgets.tabs) do
        set("tab" .. index, widget, texts.tabs[index])
    end

    for index, widget in ipairs(widgets.rows) do
        set("row" .. index, widget, texts.rows[index])
    end
end

return Overlay
