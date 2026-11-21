local Bridge = require("bridge")
local SubtitleStyle = require("subtitle_style")
local Unreal = require("unreal")

local Banner = {}

local BANNER_SECONDS = 6
local PANDORA_APP_ID = "PandoraMediaInc.29680B314EFC2_n619g4d5j0fnw!App"

-- One banner per UE4SS mod Lua state; all widgets are owned and accessed on the game thread.
local bodyWidget
local lastError
local ownerAddress
local retryAt = 0
local shownAt
local shownKey
local shownNotification
local titleWidget

local currentEvent
local lastReadAt
local lastShownNotification
local lastShownTrack
local notedExpired
local notedNotification
local notedWaiting

local function hide(reason, now)
    if titleWidget then
        Unreal.log(
            string.format(
                "banner dismissed: %s, age=%ds",
                reason or "error cleanup",
                shownAt and ((now or os.time()) - shownAt) or 0
            )
        )
    end

    if titleWidget and titleWidget:IsValid() then
        titleWidget:RemoveFromParent()
    end

    if bodyWidget and bodyWidget:IsValid() then
        bodyWidget:RemoveFromParent()
    end

    bodyWidget, ownerAddress, shownAt, titleWidget = nil, nil, nil, nil
    shownKey, shownNotification = nil, nil
end

---@param text string
---@return string
function Banner.truncateLine(text)
    local cutoff = utf8.offset(text, 81)

    if cutoff then
        return text:sub(1, cutoff - 1) .. "..."
    end

    return text
end

---@param event ZoneXMBannerEvent
---@return string firstLine
---@return string secondLine
function Banner.parts(event)
    local firstLine = event.title
    local secondLine = event.artist
    local isPandora = event.source == PANDORA_APP_ID

    if (not event.notification or isPandora) and event.artist ~= "" then
        firstLine, secondLine = event.artist, event.title
    end

    firstLine = Banner.truncateLine(firstLine)

    if secondLine ~= "" then
        secondLine = " - " .. Banner.truncateLine(secondLine)
    end

    return firstLine, secondLine
end

local function position(playerController)
    local layout = StaticFindObject("/Script/UMG.Default__WidgetLayoutLibrary")
    assert(layout and layout:IsValid(), "viewport layout library unavailable")

    local viewport = layout:GetViewportSize(playerController)
    local scale = layout:GetViewportScale(playerController)
    assert(
        scale > 0
            and scale < math.huge
            and viewport.X > 0
            and viewport.X < math.huge
            and viewport.Y > 0
            and viewport.Y < math.huge,
        "invalid banner viewport dimensions/DPI"
    )

    local height = viewport.Y / scale
    local width = viewport.X / scale
    local insetX = math.min(64, width / 10)
    local insetY = math.min(80, height / 10)
    local boxHeight = math.min(100, height - 2 * insetY)
    local boxWidth = math.min(640, width - 2 * insetX)
    local bodyText = bodyWidget.CommonTextObj
    local titleText = titleWidget.CommonTextObj
    bodyText:SetAutoWrapText(false)
    titleText:SetAutoWrapText(false)
    titleWidget:ForceLayoutPrepass()
    bodyWidget:ForceLayoutPrepass()

    local bodyWidth = bodyText:GetDesiredSize().X
    local titleWidth = titleText:GetDesiredSize().X
    local hasBody = bodyText:GetText():ToString() ~= ""
    titleWidth = math.min(titleWidth, hasBody and boxWidth / 2 or boxWidth)
    bodyWidth = hasBody and math.min(bodyWidth, boxWidth - titleWidth) or 0

    local positionX = width - insetX - titleWidth - bodyWidth
    local positionY = height - insetY - boxHeight

    for _, part in ipairs({
        { positionX = positionX, widget = titleWidget, width = titleWidth },
        { positionX = positionX + titleWidth, widget = bodyWidget, width = math.max(1, bodyWidth) },
    }) do
        part.widget.CommonTextObj:SetAutoWrapText(true)
        part.widget:SetDesiredSizeInViewport({ X = part.width, Y = boxHeight })
        -- Nonzero viewport anchors read back as zero in this game.
        part.widget:SetPositionInViewport({ X = part.positionX, Y = positionY }, false)
        part.widget:SetAnchorsInViewport({ Maximum = { X = 0, Y = 0 }, Minimum = { X = 0, Y = 0 } })
        part.widget:SetAlignmentInViewport({ X = 0, Y = 0 })
    end
end

local function show(playerController, event, now)
    local speakerStyle, bodyStyle = SubtitleStyle.get(playerController)
    titleWidget = Unreal.createTextWidget(playerController)
    bodyWidget = Unreal.createTextWidget(playerController)

    local title, body = Banner.parts(event)

    for _, part in ipairs({
        { source = speakerStyle, text = title, widget = titleWidget },
        { source = bodyStyle, text = body, widget = bodyWidget },
    }) do
        part.widget:SetVisibility(4) -- HitTestInvisible: never take mouse/game input.
        part.widget:AddToViewport(10)
        part.widget:SetText(FText(part.text))

        local text = part.widget.CommonTextObj
        assert(text and text:IsValid(), "banner text block unavailable")
        text:SetJustification(0)
        Unreal.copyTextStyle(text, part.source)
    end

    position(playerController)
    ownerAddress, shownAt = playerController:GetAddress(), now
    shownKey, shownNotification = event.key, event.notification

    if event.notification then
        lastShownNotification = event.key
    else
        lastShownTrack = event.key
    end

    Unreal.log(event.notification and "notification banner shown" or "now-playing banner shown")
end

local function wasShown(event)
    if event.notification then
        return event.key == lastShownNotification
    end

    return event.key == lastShownTrack
end

---@param now number Unix time in seconds.
function Banner.tick(now, playerController)
    if now < retryAt then
        return
    end

    local succeeded, bannerError = pcall(function()
        local playerValid = playerController and playerController:IsValid()

        if
            SubtitleStyle.ownerAddress
            and (not playerValid or SubtitleStyle.ownerAddress ~= playerController:GetAddress())
        then
            SubtitleStyle.clear()
        end

        if lastReadAt ~= now then
            if
                playerValid
                and playerController.Pawn
                and playerController.Pawn:IsValid()
                and not SubtitleStyle.hasCache()
            then
                SubtitleStyle.capture(playerController)
            end

            local notification, companionActive, expiredKey, expiredAge = Bridge.readNotification(now)

            if companionActive then
                currentEvent = notification
            else
                currentEvent = Bridge.readTrack(now)
            end

            lastReadAt = now

            -- Metadata only: correlate events without logging notification contents.
            if notification and notification.key ~= notedNotification then
                notedNotification = notification.key
                Unreal.log(string.format("notification event received by game (age=%ds)", notification.age))
            end

            if expiredKey and expiredKey ~= lastShownNotification and expiredKey ~= notedExpired then
                notedExpired = expiredKey
                Unreal.log(
                    string.format(
                        "notification not displayed: event age %ds is outside the 30-second window",
                        expiredAge
                    )
                )
            end
        end

        if not currentEvent and not titleWidget then
            return
        end

        local ready = playerValid and playerController.Pawn and playerController.Pawn:IsValid()

        if ready then
            local gameplay = StaticFindObject("/Script/Engine.Default__GameplayStatics")
            assert(gameplay and gameplay:IsValid(), "GameplayStatics unavailable")
            ready = not gameplay:IsGamePaused(playerController)
        end

        if titleWidget then
            local reason

            if not ready then
                reason = "paused/no player"
            elseif not currentEvent then
                reason = "source idle/stale"
            elseif ownerAddress ~= playerController:GetAddress() then
                reason = "player changed"
            elseif now - shownAt >= BANNER_SECONDS then
                reason = "six-second expiry"
            elseif currentEvent.key ~= shownKey or currentEvent.notification ~= shownNotification then
                reason = "new event/source"
            end

            if reason then
                hide(reason, now)
            end
        end

        -- Combat and dialogue do not defer banners; only pause/absence does.
        if ready and currentEvent and not wasShown(currentEvent) then
            show(playerController, currentEvent, now)
        elseif titleWidget then
            position(playerController)
        elseif
            not ready
            and currentEvent
            and currentEvent.notification
            and not wasShown(currentEvent)
            and currentEvent.key ~= notedWaiting
        then
            notedWaiting = currentEvent.key
            Unreal.log("notification waiting: game paused or no player")
        end
    end)

    if not succeeded then
        if tostring(bannerError) ~= lastError then
            Unreal.log("banner ERROR: " .. tostring(bannerError))
        end

        lastError = tostring(bannerError)
        Unreal.attempt("banner cleanup", hide)
        Unreal.attempt("subtitle cache cleanup", SubtitleStyle.clear)
        currentEvent, lastReadAt = nil, nil
        retryAt = now + 10
    elseif lastError then
        Unreal.log("banner recovered")
        lastError = nil
    end
end

return Banner
