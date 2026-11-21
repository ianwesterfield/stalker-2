local Bridge = require("bridge")
local Unreal = require("unreal")

local SubtitleStyle = {}

local FIELD_COUNT = 25

-- Viewport-owned collapsed widgets retain UObject-backed styling for this player's lifetime.
local bodyWidget
local lastSaveError
local lastStyleNote
local savedStyleText
local speakerWidget

local function note(message)
    if message ~= lastStyleNote then
        Unreal.log(message)
        lastStyleNote = message
    end
end

function SubtitleStyle.clear()
    if speakerWidget and speakerWidget:IsValid() then
        speakerWidget:RemoveFromParent()
    end

    if bodyWidget and bodyWidget:IsValid() then
        bodyWidget:RemoveFromParent()
    end

    bodyWidget, speakerWidget, SubtitleStyle.ownerAddress = nil, nil, nil
end

function SubtitleStyle.hasCache()
    return speakerWidget
        and speakerWidget:IsValid()
        and bodyWidget
        and bodyWidget:IsValid()
        and speakerWidget.CommonTextObj
        and speakerWidget.CommonTextObj:IsValid()
        and bodyWidget.CommonTextObj
        and bodyWidget.CommonTextObj:IsValid()
end

local function liveSubtitleView()
    local function usable(view)
        return view
            and view:IsValid()
            and view.SpeakerDialogText
            and view.SpeakerDialogText:IsValid()
            and view.TextDialog
            and view.TextDialog:IsValid()
            and view.SpeakerDialogText.CommonTextObj
            and view.SpeakerDialogText.CommonTextObj:IsValid()
            and view.TextDialog.CommonTextObj
            and view.TextDialog.CommonTextObj:IsValid()
    end

    local view = FindFirstOf("SubtitleView")

    if usable(view) then
        return view
    end

    for _, candidate in ipairs(FindAllOf("SubtitleView") or {}) do
        if usable(candidate) and not candidate:GetFullName():find("Default__") then
            return candidate
        end
    end
end

local function objectPath(object)
    if not (object and object.IsValid and object:IsValid()) then
        return ""
    end

    local path = object:GetFullName():gsub("^%S+%s+", "")
    assert(path ~= "" and not path:find("[|\n]"), "unsupported subtitle style asset path")

    return path
end

local function describeText(role, text)
    local function number(value)
        value = tonumber(value)
        assert(value and value == value and math.abs(value) < math.huge, "subtitle style value unavailable")

        return string.format("%.9g", value)
    end

    local function flag(value)
        return value and "1" or "0"
    end

    local font = text.Font
    local color = text.ColorAndOpacity.SpecifiedColor
    local outline = font.OutlineSettings
    local shadow = text.ShadowColorAndOpacity
    local edge = outline.OutlineColor
    local typeface = font.TypefaceFontName

    if type(typeface) ~= "string" then
        typeface = typeface:ToString()
    end

    assert(not typeface:find("[|\n]"), "unsupported subtitle typeface name")

    -- Positional wire format: channel and field order must remain compatible with existing caches.
    local fields = {
        role,
        objectPath(font.FontObject),
        objectPath(font.FontMaterial),
        typeface,
        number(font.Size),
        number(font.LetterSpacing),
        number(outline.OutlineSize),
        objectPath(outline.OutlineMaterial),
        number(edge.R),
        number(edge.G),
        number(edge.B),
        number(edge.A),
        flag(outline.bSeparateFillAlpha),
        flag(outline.bApplyOutlineToDropShadows),
        number(color.R),
        number(color.G),
        number(color.B),
        number(color.A),
        number(text.ColorAndOpacity.ColorUseRule or 0),
        number(text.ShadowOffset.X),
        number(text.ShadowOffset.Y),
        number(shadow.R),
        number(shadow.G),
        number(shadow.B),
        number(shadow.A),
    }
    assert(fields[2] ~= "", "subtitle font asset unavailable")

    return table.concat(fields, "|")
end

local function save(subtitles)
    local text = "ZoneXM/style/1\n"
        .. describeText("speaker", subtitles.SpeakerDialogText.CommonTextObj)
        .. "\n"
        .. describeText("body", subtitles.TextDialog.CommonTextObj)
        .. "\n"

    if text == savedStyleText then
        return
    end

    local file, openError = io.open(Bridge.STYLE_PATH, "wb")
    assert(file, "cannot save subtitle style: " .. tostring(openError))

    local written, writeError = file:write(text)
    local closed, closeError = file:close()
    assert(written, "cannot save subtitle style: " .. tostring(writeError))
    assert(closed, "cannot close subtitle style: " .. tostring(closeError))

    savedStyleText = text
    Unreal.log("subtitle style saved for sessions that start without subtitles")
end

local function findAsset(path, required)
    if path == "" then
        return nil
    end

    local object = StaticFindObject(path)

    if
        not (object and object:IsValid())
        and type(LoadAsset) == "function"
        and not path:find("^/Engine/Transient")
    then
        object = LoadAsset(path)
    end

    if object and object:IsValid() then
        return object
    end

    assert(not required, "saved subtitle font is not loaded")
    note("saved subtitle style: optional material unavailable; using font without it")
end

local function parseTextStyle(line, role)
    local fields = {}

    for field in (line .. "|"):gmatch("([^|]*)|") do
        fields[#fields + 1] = field
    end

    assert(#fields == FIELD_COUNT and fields[1] == role, "invalid saved subtitle style")

    local function number(fieldIndex)
        return assert(tonumber(fields[fieldIndex]), "invalid saved subtitle style number")
    end

    local function color(fieldIndex)
        return {
            R = number(fieldIndex),
            G = number(fieldIndex + 1),
            B = number(fieldIndex + 2),
            A = number(fieldIndex + 3),
        }
    end

    local font = {
        FontObject = findAsset(fields[2], true),
        FontMaterial = findAsset(fields[3]),
        TypefaceFontName = FName(fields[4]),
        Size = number(5),
        LetterSpacing = number(6),
        OutlineSettings = {
            OutlineColor = color(9),
            OutlineMaterial = findAsset(fields[8]),
            OutlineSize = number(7),
            bApplyOutlineToDropShadows = fields[14] == "1",
            bSeparateFillAlpha = fields[13] == "1",
        },
    }

    return {
        ColorAndOpacity = { ColorUseRule = number(19), SpecifiedColor = color(15) },
        Font = font,
        IsValid = function()
            return true
        end,
        ShadowColorAndOpacity = color(22),
        ShadowOffset = { X = number(20), Y = number(21) },
    }
end

local function loadSaved()
    local data = Bridge.readSnapshot(Bridge.STYLE_PATH)

    if not data then
        return nil
    end

    local speaker, body = data:match("^ZoneXM/style/1\n([^\n]+)\n([^\n]+)\n$")
    assert(speaker, "invalid saved subtitle style")

    return parseTextStyle(speaker, "speaker"), parseTextStyle(body, "body")
end

local function fallback(red, green, blue)
    return {
        ColorAndOpacity = { ColorUseRule = 0, SpecifiedColor = { R = red, G = green, B = blue, A = 1 } },
        IsValid = function()
            return true
        end,
        ShadowColorAndOpacity = { R = 0, G = 0, B = 0, A = 0.85 },
        ShadowOffset = { X = 1, Y = 1 },
    }
end

function SubtitleStyle.capture(playerController)
    local subtitles = liveSubtitleView()

    if not subtitles then
        return
    end

    if not SubtitleStyle.hasCache() then
        SubtitleStyle.clear()
        speakerWidget = Unreal.createTextWidget(playerController)
        bodyWidget = Unreal.createTextWidget(playerController)
        assert(SubtitleStyle.hasCache(), "subtitle cache widget creation failed")

        for _, widget in ipairs({ speakerWidget, bodyWidget }) do
            widget:SetVisibility(1) -- Collapsed: retain objects without layout, rendering or input.
            widget:AddToViewport(0)
        end

        SubtitleStyle.ownerAddress = playerController:GetAddress()
        Unreal.log("subtitle styling retained for this player")
    end

    Unreal.copyTextStyle(speakerWidget.CommonTextObj, subtitles.SpeakerDialogText.CommonTextObj)
    Unreal.copyTextStyle(bodyWidget.CommonTextObj, subtitles.TextDialog.CommonTextObj)

    local saved, saveError = pcall(save, subtitles)

    if not saved and tostring(saveError) ~= lastSaveError then
        Unreal.log("subtitle style save ERROR: " .. tostring(saveError))
    end

    lastSaveError = not saved and tostring(saveError) or nil
end

function SubtitleStyle.get(playerController)
    local captured, captureError = pcall(SubtitleStyle.capture, playerController)

    if not captured then
        note("subtitle style capture ERROR: " .. tostring(captureError))
    end

    if SubtitleStyle.hasCache() then
        note("banner style: subtitles")
        return speakerWidget.CommonTextObj, bodyWidget.CommonTextObj
    end

    local loaded, speaker, body = pcall(loadSaved)

    if loaded and speaker then
        note("banner style: saved subtitle style (no subtitles yet this session)")
        return speaker, body
    end

    if loaded then
        note("banner style: fallback colors (subtitle style not captured yet; shows after anyone speaks)")
    else
        note("banner style: fallback colors (saved subtitle style unusable: " .. tostring(speaker) .. ")")
    end

    return fallback(1, 0.72, 0.1), fallback(1, 1, 1)
end

return SubtitleStyle
