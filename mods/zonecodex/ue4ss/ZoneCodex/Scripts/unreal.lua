local UEHelpers = require("UEHelpers")

local Unreal = {
    AK_STATICS = "/Script/AkAudio.Default__AkGameplayStatics",
    CPP_MEDIATOR = "/Script/Stalker2.Default__CppMediator",
    IMAGE_CLASS = "/Script/UMG.Image",
    INTERNATIONALIZATION_LIBRARY = "/Script/Engine.Default__KismetInternationalizationLibrary",
    LAYOUT_LIBRARY = "/Script/UMG.Default__WidgetLayoutLibrary",
    LOCALIZATION_NAMESPACE = "ST_S2BaseGameLocalization",
    SCROLL_BOX_CLASS = "/Script/UMG.ScrollBox",
    SIZE_BOX_CLASS = "/Script/UMG.SizeBox",
    SPACER_CLASS = "/Script/UMG.Spacer",
    TEXT_LIBRARY = "/Script/Engine.Default__KismetTextLibrary",
    TEXT_WIDGET = "/Game/GameLite/FPS_Game/UIRemaster/CommonWidgets/W_Text.W_Text_C",
    WIDGET_LIBRARY = "/Script/UMG.Default__WidgetBlueprintLibrary",
}

-- Assets that failed to load stay failed for the session instead of retrying every render.
local missingAssets = {}
local assets = {}
local soundWarned = false

function Unreal.log(message)
    print("[ZoneCodex] " .. message .. "\n")
end

function Unreal.isValid(object)
    local ok, valid = pcall(function()
        return object ~= nil and object:IsValid()
    end)

    return ok and valid == true
end

function Unreal.isDefault(object)
    local ok, fullName = pcall(function()
        return object:GetFullName()
    end)

    return not ok or fullName:find("Default__", 1, true) ~= nil
end

function Unreal.playerController()
    local controller = UEHelpers.GetPlayerController()
    return Unreal.isValid(controller) and controller or nil
end

function Unreal.playerPawn()
    local controller = Unreal.playerController()
    local pawn = controller and controller.Pawn
    return Unreal.isValid(pawn) and pawn or nil
end

function Unreal.createTextWidget(controller)
    local library = StaticFindObject(Unreal.WIDGET_LIBRARY)
    local class = StaticFindObject(Unreal.TEXT_WIDGET)

    assert(Unreal.isValid(library) and Unreal.isValid(class), "text widget prerequisites unavailable")

    local widget = library:Create(controller, class, controller)

    assert(Unreal.isValid(widget), "text widget creation failed")
    return widget
end

-- A W_Text styled by one of the game's font style ids (PDAQuestSlotName, ...). The style
-- manager applies it on construction, so call this before adding the widget to a panel.
function Unreal.createStyledText(controller, styleId)
    local widget = Unreal.createTextWidget(controller)

    local function styleApplied()
        local ok, current = pcall(function()
            local value = widget.TextSettings.FontStyleId
            return type(value) == "string" and value or value:ToString()
        end)

        return ok and current == styleId
    end

    -- FName defaults to find-only lookup; add the name if the style's asset isn't loaded yet.
    local nameValue = FName and (EFindName and EFindName.FNAME_Add and FName(styleId, EFindName.FNAME_Add) or FName(styleId))

    for _, value in ipairs({ nameValue or styleId, styleId }) do
        pcall(function()
            widget.TextSettings.FontStyleId = value
        end)

        if styleApplied() then
            break
        end
    end

    pcall(function()
        widget.TextSettings.bUseFontColor = true
        widget.bEnableStyleManager = true
    end)

    return widget, styleApplied()
end

-- A native UMG widget (Image, ScrollBox, ...) owned by `outer` (a widget tree).
function Unreal.createWidget(classPath, outer)
    assert(type(StaticConstructObject) == "function", "StaticConstructObject unavailable")

    local class = StaticFindObject(classPath)

    assert(Unreal.isValid(class), classPath .. " class unavailable")

    local widget = StaticConstructObject(class, outer)

    assert(Unreal.isValid(widget), classPath .. " construction failed")
    return widget
end

-- A plain UMG Image; with no texture it draws a solid, tinted rectangle.
function Unreal.createImage(outer)
    return Unreal.createWidget(Unreal.IMAGE_CLASS, outer)
end

local function loadAsset(path, kind)
    if path == "" or missingAssets[path] then
        return nil
    end

    -- Lua references do not keep assets alive, so cached assets are re-validated.
    local asset = assets[path]

    if Unreal.isValid(asset) then
        return asset
    end

    asset = StaticFindObject(path)

    if not Unreal.isValid(asset) and type(LoadAsset) == "function" then
        local ok, loaded = pcall(LoadAsset, path)
        asset = ok and loaded or nil
    end

    if Unreal.isValid(asset) then
        assets[path] = asset
        return asset
    end

    missingAssets[path] = true
    Unreal.log(kind .. " unavailable: " .. path)
end

---@param path string Texture2D object path ("/Game/.../T_name.T_name").
function Unreal.loadTexture(path)
    return loadAsset(path, "texture")
end

-- Posts a Wwise UI event (AkAudioEvent object path) at the player, so it sounds centred.
-- Sound is cosmetic: failures are logged once and never interrupt the page.
function Unreal.playSound(path)
    local event = loadAsset(path, "sound")

    if not event then
        return false
    end

    local ok, errorMessage = pcall(function()
        local pawn = Unreal.playerPawn()
        local location = pawn and pawn:K2_GetActorLocation() or { X = 0, Y = 0, Z = 0 }
        local context = pawn or Unreal.playerController()

        StaticFindObject(Unreal.AK_STATICS):PostEventAtLocation(event, location, { Pitch = 0, Roll = 0, Yaw = 0 }, context)
    end)

    if not ok and not soundWarned then
        soundWarned = true
        Unreal.log("UI sound failed (" .. tostring(errorMessage) .. "); continuing silently")
    end

    return ok
end

-- The game's active culture ("en", "uk", ...), or nil when it can't be read.
function Unreal.currentCulture()
    local ok, culture = pcall(function()
        local value = StaticFindObject(Unreal.INTERNATIONALIZATION_LIBRARY):GetCurrentCulture()
        return type(value) == "string" and value or value:ToString()
    end)

    return ok and type(culture) == "string" and culture ~= "" and culture or nil
end

-- A vanilla localization key's text in the game's current language, or nil if the game has no
-- such entry. UE4SS writes the OutText out-param into the table passed for it.
function Unreal.localizedText(key)
    local ok, text = pcall(function()
        local outText = {}
        local found = StaticFindObject(Unreal.TEXT_LIBRARY):FindTextInLocalizationTable(
            Unreal.LOCALIZATION_NAMESPACE,
            key,
            outText,
            ""
        )
        local value = outText.OutText

        if not found or value == nil then
            return nil
        end

        return type(value) == "string" and value or value:ToString()
    end)

    return ok and type(text) == "string" and text ~= "" and text or nil
end

function Unreal.textureSize(texture)
    local ok, width, height = pcall(function()
        return texture:Blueprint_GetSizeX(), texture:Blueprint_GetSizeY()
    end)

    if ok and type(width) == "number" and type(height) == "number" and width > 0 and height > 0 then
        return width, height
    end

    return 1, 1
end

-- The cursor in desktop pixels, for diagnostics; nil if unavailable.
function Unreal.mousePosition()
    local ok, position = pcall(function()
        return StaticFindObject(Unreal.LAYOUT_LIBRARY):GetMousePositionOnPlatform()
    end)

    if ok and type(position) ~= "nil" and type(position.X) == "number" and type(position.Y) == "number" then
        return { X = position.X, Y = position.Y }
    end

    return nil
end

-- Viewport size in Slate units, which is what SetPositionInViewport(..., false) expects.
function Unreal.viewportSize(controller)
    local layout = StaticFindObject(Unreal.LAYOUT_LIBRARY)

    assert(Unreal.isValid(layout), "viewport layout library unavailable")

    local size, scale = layout:GetViewportSize(controller), layout:GetViewportScale(controller)

    assert(scale > 0 and size.X > 0 and size.Y > 0, "invalid viewport dimensions/DPI")
    return size.X / scale, size.Y / scale
end

return Unreal
