local Catalog = require("catalog")
local Unreal = require("unreal")
local Toast = {}
local shownAt, widget

function Toast.hide()
    if widget then
        local ok, errorMessage = pcall(function()
            if Unreal.isValid(widget) then
                widget:RemoveFromParent()
            end
        end)

        if not ok then
            Unreal.log("toast cleanup failed: " .. tostring(errorMessage))
        end
    end

    shownAt, widget = nil, nil
end

function Toast.show(text, now)
    Toast.hide()

    if Catalog.config.ToastSeconds <= 0 then
        return
    end

    local ok, errorMessage = pcall(function()
        local controller
        widget, controller = Unreal.createWidget(Unreal.TEXT_WIDGET)
        shownAt = now
        
        widget:SetVisibility(4) -- HitTestInvisible: never take PDA mouse input.
        widget:AddToViewport(1000)
        widget:SetText(FText(text))
        
        local textObject = widget.CommonTextObj

        if Unreal.isValid(textObject) then
            textObject:SetJustification(1)
            textObject:SetColorAndOpacity({
                SpecifiedColor = { R = 1, G = 0.72, B = 0.1, A = 1 },
                ColorUseRule = 0,
            })
            
            textObject:SetShadowOffset({ X = 1, Y = 1 })
            textObject:SetShadowColorAndOpacity({ R = 0, G = 0, B = 0, A = 0.85 })
        end

        local layout = StaticFindObject("/Script/UMG.Default__WidgetLayoutLibrary")
        assert(Unreal.isValid(layout), "toast layout unavailable")
        
        local size, scale = layout:GetViewportSize(controller), layout:GetViewportScale(controller)
        assert(scale > 0 and size.X > 0 and size.Y > 0, "invalid viewport")
        
        local height, width = size.Y / scale, size.X / scale
        local boxWidth = math.min(640, width - 64)
        
        widget:SetDesiredSizeInViewport({ X = boxWidth, Y = 48 })
        widget:SetAnchorsInViewport({ Minimum = { X = 0, Y = 0 }, Maximum = { X = 0, Y = 0 } })
        widget:SetAlignmentInViewport({ X = 0, Y = 0 })
        widget:SetPositionInViewport({ X = (width - boxWidth) / 2, Y = height * 0.06 }, false)
    end)

    if not ok then
        Unreal.log("toast ERROR: " .. tostring(errorMessage))
        Toast.hide()
    end
end

function Toast.tick(now)
    if shownAt and now - shownAt >= Catalog.config.ToastSeconds then
        Toast.hide()
    end
end

return Toast
