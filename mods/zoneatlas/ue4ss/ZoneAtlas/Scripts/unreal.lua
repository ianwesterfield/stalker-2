local UEHelpers = require("UEHelpers")

local Unreal = {
    TEXT_WIDGET = "/Game/GameLite/FPS_Game/UIRemaster/CommonWidgets/W_Text.W_Text_C",
}

function Unreal.log(message)
    print("[ZoneAtlas] " .. message .. "\n")
end

function Unreal.isValid(object)
    local ok, valid = pcall(function()
        return object ~= nil and object:IsValid()
    end)

    return ok and valid == true
end

function Unreal.objectPath(object)
    local fullName = object:GetFullName()
    return fullName:match("^%S+%s+(.+)$") or fullName
end

function Unreal.isDefault(object)
    local ok, fullName = pcall(function()
        return object:GetFullName()
    end)

    return not ok or fullName:find("Default__", 1, true) ~= nil
end

function Unreal.createWidget(class)
    local controller = UEHelpers.GetPlayerController()
    local library = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")

    if type(class) == "string" then
        class = StaticFindObject(class)
    end

    assert(
        Unreal.isValid(controller) and Unreal.isValid(library) and Unreal.isValid(class),
        "widget prerequisites unavailable"
    )
    local widget = library:Create(controller, class, controller)
    assert(Unreal.isValid(widget), "widget creation failed")
    
    return widget, controller
end

return Unreal
