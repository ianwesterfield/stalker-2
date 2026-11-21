local Unreal = {}

local TEXT_WIDGET = "/Game/GameLite/FPS_Game/UIRemaster/CommonWidgets/W_Text.W_Text_C"
local errors = {}

function Unreal.log(message)
    print("[ZoneXM] " .. message .. "\n")
end

function Unreal.attempt(operation, callback, ...)
    local succeeded, result = pcall(callback, ...)

    if not succeeded then
        local message = tostring(result)

        if errors[operation] ~= message then
            Unreal.log(operation .. " ERROR: " .. message)
            errors[operation] = message
        end
    else
        errors[operation] = nil
    end

    return succeeded, result
end

function Unreal.createTextWidget(playerController)
    local library = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
    local widgetClass = StaticFindObject(TEXT_WIDGET)
    assert(
        library and library:IsValid() and widgetClass and widgetClass:IsValid(),
        "subtitle text widget class unavailable"
    )

    local widget = library:Create(playerController, widgetClass, playerController)
    assert(widget and widget:IsValid(), "subtitle text widget creation failed")

    return widget
end

function Unreal.copyTextStyle(target, source)
    assert(source and source:IsValid(), "subtitle text style unavailable")

    if source.Font then
        target:SetFont(source.Font)
    end

    target:SetColorAndOpacity(source.ColorAndOpacity)
    target:SetShadowOffset(source.ShadowOffset)
    target:SetShadowColorAndOpacity(source.ShadowColorAndOpacity)
end

return Unreal
