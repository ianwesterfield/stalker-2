local Unreal = require("unreal")

local WorldMap = {}
local nextSceneSearch = 0
local page, pageSeen

local notifyOk, notifyError = pcall(function()
    NotifyOnNewObject("/Script/Stalker2.WorldMapPage", function(object)
        pageSeen = object
    end)
end)

if not notifyOk then
    Unreal.log("map page notifications unavailable: " .. tostring(notifyError))
end

function WorldMap.reset()
    WorldMap.scene, page, pageSeen = nil, nil, nil
end

function WorldMap.findScene(now)
    if Unreal.isValid(WorldMap.scene) then
        return WorldMap.scene
    end

    WorldMap.scene = nil

    if now < nextSceneSearch then
        return nil
    end

    nextSceneSearch = now + 2

    for _, className in ipairs({ "BP_WorldMapScene_C", "WorldMapScene" }) do
        local scene = FindFirstOf(className)

        if Unreal.isValid(scene) then
            WorldMap.scene = scene
            Unreal.log("world map scene: " .. scene:GetFullName())
            return scene
        end
    end
end

function WorldMap.material(scene)
    local mesh = scene.Map
    local material = Unreal.isValid(mesh) and mesh:GetMaterial(0)

    if Unreal.isValid(material) and material:GetClass():GetFName():ToString() == "MaterialInstanceDynamic" then
        return material
    end
end

function WorldMap.currentPage(scan)
    if pageSeen then
        if Unreal.isValid(pageSeen) and not Unreal.isDefault(pageSeen) then
            page = pageSeen
        end

        pageSeen = nil
    end

    if Unreal.isValid(page) then
        return page
    end

    page = nil

    -- Full object-array walks are only allowed on input, not on every poll.
    if scan then
        for _, candidate in ipairs(FindAllOf("WorldMapPage") or {}) do
            if Unreal.isValid(candidate) and not Unreal.isDefault(candidate) then
                page = page or candidate

                if candidate:IsVisible() then
                    page = candidate
                    break
                end
            end
        end
    end

    return page
end

function WorldMap.isOpen(scene)
    local captureOk, capturesEveryFrame = pcall(function()
        return scene.SceneCaptureComponent.bCaptureEveryFrame
    end)

    if captureOk and capturesEveryFrame == true then
        return true
    end

    local renderOk, wasRecentlyRendered = pcall(function()
        return scene.Map:WasRecentlyRendered(0.5)
    end)

    if renderOk and wasRecentlyRendered == true then
        return true
    end

    local pageOk, isPageVisible = pcall(function()
        local mapPage = WorldMap.currentPage(true)
        return mapPage and mapPage:IsVisible()
    end)

    if pageOk and isPageVisible == true then
        return true
    end

    Unreal.log(
        string.format(
            "map-open check: captureEveryFrame=%s recentlyRendered=%s pageVisible=%s",
            tostring(capturesEveryFrame),
            tostring(wasRecentlyRendered),
            tostring(isPageVisible)
        )
    )

    return not (
        (captureOk and type(capturesEveryFrame) == "boolean")
        or (renderOk and type(wasRecentlyRendered) == "boolean")
        or (pageOk and isPageVisible ~= nil)
    )
end

function WorldMap.refreshCapture(scene)
    local ok, errorMessage = pcall(function()
        local capture = scene.SceneCaptureComponent

        if Unreal.isValid(capture) and not capture.bCaptureEveryFrame then
            capture:CaptureScene()
        end
    end)

    if not ok then
        Unreal.log("map capture refresh failed: " .. tostring(errorMessage))
    end
end

return WorldMap
