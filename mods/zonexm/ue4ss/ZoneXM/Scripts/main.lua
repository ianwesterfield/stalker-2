-- Zone XM — conversation awareness for external music.
-- Ducks for the sounds of people AND the things that hunt them: gunfire near
-- Skif, dialogue, nearby voices, and mutants inside his AI sphere (dogs don't
-- announce themselves — the gunfire tier is deaf to teeth).
-- Gunfire: ItemAppearanceComponent:OnShotSoundStart (sole VM dispatch of 7).
-- Dialogue: PC:IsInStaticDialog polled — queryable, zero patch risk.
-- Voices/melee: notify batteries under live test (prune like the gun tier).
-- Mutants: FindAllOf(AnimInstanceMutant) sweep — only spawned mutants animate,
-- IsAlive filters corpses. No property reflection (that's what pegged zxprobe).
-- Optional read-only Windows media snapshots drive a separate now-playing widget.
local UEHelpers = require("UEHelpers")
local function log(msg) print("[ZoneXM] " .. msg .. "\n") end

assert(type(LoopInGameThreadWithDelay) == "function",
    "ZoneXM requires UE4SS LoopInGameThreadWithDelay")

local FLAG_DIR = os.getenv("LOCALAPPDATA") .. "\\Stalker2\\Saved\\ZoneXM"
-- no os.execute here: cmd flash at boot stole game input capture (mouse stuck till menu toggle);
-- the watchdog creates this dir, and writeFlag just no-ops until it exists
local FLAG = FLAG_DIR .. "\\alert.flag"
local TRACK_FILE = FLAG_DIR .. "\\now-playing.txt"
local NOTIFICATION_FILE = FLAG_DIR .. "\\notification.txt"
local STYLE_FILE = FLAG_DIR .. "\\subtitle-style.txt"

local POLL_MS = 250
local HOLDOFF_MS = 6000      -- gunfire keeps the flag hot this long after the last shot
local TALK_HOLDOFF_MS = 2500 -- voices get a shorter tail (conversation ends = music back)
local HEARTBEAT_MS = 3000    -- watchdog treats a flag older than 8s as a dead game
local DANGER_RADIUS = 6000   -- cm; sounds beyond this aren't your scene
local BEAST_RADIUS = 3500    -- cm; a live mutant this close = duck NOW
local BEAST_HOLDOFF_MS = 3000  -- radar self-refreshes while they linger; short tail
local BEAST_SWEEP_MS = 750   -- radar cadence (lighter than the flag poll)

local lastHitAt = 0.0        -- wall ms; written by hooks, read by the poll
local lastTalkAt = 0.0
local lastBeastAt = 0.0
local hitCount = 0
local talkCount = 0
local beastCount = 0

local function nearPlayer(who)
    local pawn, ploc
    pcall(function() pawn = UEHelpers.GetPlayerController().Pawn end)
    if not (pawn and pawn:IsValid()) then return false end
    pcall(function() ploc = pawn:K2_GetActorLocation() end)
    if not ploc then return true end   -- can't measure = assume it matters
    local l
    pcall(function() l = who:K2_GetActorLocation() end)
    if not l then pcall(function() l = who:GetOwner():K2_GetActorLocation() end) end  -- components
    if not l then return true end      -- unlocatable dispatcher: assume it's your fight
    local dx, dy, dz = l.X - ploc.X, l.Y - ploc.Y, l.Z - ploc.Z
    return dx * dx + dy * dy + dz * dz <= DANGER_RADIUS * DANGER_RADIUS
end

local rawByFn = {}
local function armBattery(fns, onNear)
    for _, fn in ipairs(fns) do
        local short = fn:match(":([^:]+)$")
        local ok, err = pcall(function()
            RegisterHook(fn, function(self)
                local fired = pcall(function()
                    local who = self:get()
                    if not (who and who:IsValid()) then return end
                    local n = (rawByFn[short] or 0) + 1
                    rawByFn[short] = n
                    if n <= 3 then log(short .. " fired raw (#" .. n .. ")") end
                    if nearPlayer(who) then onNear(short) end
                end)
            end)
        end)
        log("hook " .. short .. (ok and " armed" or (" FAILED: " .. tostring(err))))
    end
end

armBattery({
    "/Script/Stalker2.ItemAppearanceComponent:OnShotSoundStart", -- the ONE proven VM dispatch
    -- Dead (never dispatch through the VM, proven by live fire): OnDamageReceived_BP,
    -- OnShot_BP, OnShootingStarted_BP, OnFirePressed[_BP], ShootingWeaponComponent:Shoot.
    -- Obj:OnHit is OUT: per-physics-contact on characters; pegged the game thread.
}, function(short)
    lastHitAt = os.time() * 1000
    hitCount = hitCount + 1
    if hitCount <= 3 then log("combat near Skif (#" .. hitCount .. ") via " .. short) end
end)

armBattery({
    "/Script/Stalker2.Obj:OnMeleeAttack_BP",  -- the lunge itself (candidate; attack-rate-bounded)
    "/Script/Stalker2.Obj:MakeAttack_BP",
    -- Dead voice candidates (armed, never fired through live chatter + a dialog):
    -- CppMediator:CreateAIVoiceEvent, SoundWaveSpeechComponent:OnVoicegenFinished.
    -- Speech detection lives in the poll now: SubtitleView visibility.
}, function(short)
    lastBeastAt = os.time() * 1000
    beastCount = beastCount + 1
    if beastCount <= 3 then log("melee near Skif (#" .. beastCount .. ") via " .. short) end
end)

-- mutant radar: anything with a mutant anim instance, alive, inside the sphere
local radarLogs = 0
LoopInGameThreadWithDelay(BEAST_SWEEP_MS, function()
    pcall(function()
        local pawn = UEHelpers.GetPlayerController().Pawn
        if not (pawn and pawn:IsValid()) then return end
        local ploc = pawn:K2_GetActorLocation()
        local insts = FindAllOf("AnimInstanceMutant") or {}
        local found = false
        for _, inst in ipairs(insts) do
            pcall(function()
                local beast = inst:GetOwningActor()
                if beast and beast:IsValid() and beast:IsAlive() then
                    local l = beast:K2_GetActorLocation()
                    local dx, dy, dz = l.X - ploc.X, l.Y - ploc.Y, l.Z - ploc.Z
                    local d2 = dx * dx + dy * dy + dz * dz
                    if d2 <= BEAST_RADIUS * BEAST_RADIUS then
                        lastBeastAt = os.time() * 1000
                        found = true
                        if radarLogs < 3 then
                            radarLogs = radarLogs + 1
                            log(string.format("beast in sphere: %s at %.0fm", beast:GetClass():GetFName():ToString(), math.sqrt(d2) / 100))
                        end
                    end
                end
            end)
            if found then break end  -- one live beast is enough this sweep
        end
    end)
    return false
end)

local lastBeatAt = 0.0
local written = nil          -- nil = no file written this session yet
local writes = 0
local dialogProbe = false    -- log the IsInStaticDialog verdict once

local banner, bannerOwner, bannerAt
local bannerBody
local styleSpeaker, styleBody, styleOwner
local bannerKey, bannerKind
local lastShownTrack, currentTrack, lastTrackRead
local lastShownNotification
local notedNotification, notedWaiting, notedExpired
local savedStyleText, styleSaveError, styleNote
local bannerRetryAt = 0
local bannerError
local BANNER_SECONDS = 6
local TRACK_STALE_SECONDS = 8
local TEXT_WIDGET = "/Game/GameLite/FPS_Game/UIRemaster/CommonWidgets/W_Text.W_Text_C"

local function readSnapshot(path)
    local f, err, code = io.open(path, "rb")
    if not f then
        if code == 2 then return nil end -- bridge absent/disabled
        error("cannot read banner snapshot: " .. tostring(err))
    end
    local data = f:read(4097)
    f:close()
    assert(data and #data > 0, "empty banner snapshot")
    assert(#data <= 4096, "banner snapshot exceeds 4096 bytes")
    assert(utf8.len(data), "banner snapshot is not UTF-8")
    assert(not data:find("[%z\1-\9\11-\31\127]"), "invalid banner control characters")
    return data
end

local function readTrack(now)
    local data = readSnapshot(TRACK_FILE)
    if not data then return nil end
    local stamp, source, title, artist = data:match("^ZoneXM/1\n(%d+)\n([^\n]*)\n([^\n]*)\n([^\n]*)\n$")
    assert(stamp, "invalid now-playing snapshot")
    local age = now - tonumber(stamp)
    if age < -2 or age > TRACK_STALE_SECONDS or source == "" or title == "" then return nil end
    return { key = source .. "\n" .. title .. "\n" .. artist, title = title, artist = artist }
end

local function readNotification(now)
    local data = readSnapshot(NOTIFICATION_FILE)
    if not data then return nil, false end
    local beat, received, source, id, app, title, body = data:match(
        "^ZoneXM/notification/1\n(%d+)\n(%d+)\n([^\n]*)\n([^\n]*)\n([^\n]*)\n([^\n]*)\n([^\n]*)\n$")
    assert(beat, "invalid notification snapshot")
    local age = now - tonumber(beat)
    if age < -2 or age > TRACK_STALE_SECONDS then return nil, false end
    age = now - tonumber(received)
    -- A live notification companion owns banners, even when idle, so a song is not
    -- announced twice through independent notification and media-session sources.
    if source == "" or id == "" or title == "" then return nil, true end
    if age < -2 or age >= 30 then return nil, true, source .. "\n" .. id, age end
    return { key = source .. "\n" .. id, title = title, artist = body,
        notification = true, source = source, age = age }, true
end

local function hideBanner(reason, now)
    if banner then
        log(string.format("banner dismissed: %s, age=%ds", reason or "error cleanup",
            bannerAt and ((now or os.time()) - bannerAt) or 0))
    end
    if banner and banner:IsValid() then banner:RemoveFromParent() end
    if bannerBody and bannerBody:IsValid() then bannerBody:RemoveFromParent() end
    bannerBody = nil
    banner, bannerOwner, bannerAt = nil, nil, nil
    bannerKey, bannerKind = nil, nil
end

local function bannerLine(text)
    local cut = utf8.offset(text, 81)
    return cut and (text:sub(1, cut - 1) .. "...") or text
end

local function bannerParts(track)
    local first, second = track.title, track.artist
    local pandora = track.source == "PandoraMediaInc.29680B314EFC2_n619g4d5j0fnw!App"
    if (not track.notification or pandora) and track.artist ~= "" then
        first, second = track.artist, track.title
    end
    return bannerLine(first), second ~= "" and (" - " .. bannerLine(second)) or ""
end

local function bannerText(track)
    local title, body = bannerParts(track)
    return title .. body
end

local function subtitleStyle(target, source)
    assert(source and source:IsValid(), "subtitle text style unavailable")
    if source.Font then target:SetFont(source.Font) end
    target:SetColorAndOpacity(source.ColorAndOpacity)
    target:SetShadowOffset(source.ShadowOffset)
    target:SetShadowColorAndOpacity(source.ShadowColorAndOpacity)
end

local function clearSubtitleCache()
    if styleSpeaker and styleSpeaker:IsValid() then styleSpeaker:RemoveFromParent() end
    if styleBody and styleBody:IsValid() then styleBody:RemoveFromParent() end
    styleSpeaker, styleBody, styleOwner = nil, nil, nil
end

local function subtitleCacheValid()
    return styleSpeaker and styleSpeaker:IsValid() and styleBody and styleBody:IsValid()
        and styleSpeaker.CommonTextObj and styleSpeaker.CommonTextObj:IsValid()
        and styleBody.CommonTextObj and styleBody.CommonTextObj:IsValid()
end

local function liveSubtitleView()
    local function usable(view)
        return view and view:IsValid()
            and view.SpeakerDialogText and view.SpeakerDialogText:IsValid()
            and view.TextDialog and view.TextDialog:IsValid()
            and view.SpeakerDialogText.CommonTextObj and view.SpeakerDialogText.CommonTextObj:IsValid()
            and view.TextDialog.CommonTextObj and view.TextDialog.CommonTextObj:IsValid()
    end
    local view = FindFirstOf("SubtitleView")
    if usable(view) then return view end
    for _, candidate in ipairs(FindAllOf("SubtitleView") or {}) do
        if usable(candidate) and not candidate:GetFullName():find("Default__") then return candidate end
    end
end

-- Subtitle styles only exist after someone speaks, so a fresh load has none. Persist
-- the copied style as asset paths and values (never notification text) for later sessions.
local STYLE_FIELDS = 25

local function noteStyle(message)
    if message ~= styleNote then log(message) end
    styleNote = message
end

local function objectPath(object)
    if not (object and object.IsValid and object:IsValid()) then return "" end
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
    local function flag(value) return value and "1" or "0" end
    local font = text.Font
    local outline, color = font.OutlineSettings, text.ColorAndOpacity.SpecifiedColor
    local edge, shadow = outline.OutlineColor, text.ShadowColorAndOpacity
    local typeface = type(font.TypefaceFontName) == "string" and font.TypefaceFontName
        or font.TypefaceFontName:ToString()
    assert(not typeface:find("[|\n]"), "unsupported subtitle typeface name")
    local fields = {
        role, objectPath(font.FontObject), objectPath(font.FontMaterial), typeface,
        number(font.Size), number(font.LetterSpacing), number(outline.OutlineSize), objectPath(outline.OutlineMaterial),
        number(edge.R), number(edge.G), number(edge.B), number(edge.A),
        flag(outline.bSeparateFillAlpha), flag(outline.bApplyOutlineToDropShadows),
        number(color.R), number(color.G), number(color.B), number(color.A),
        number(text.ColorAndOpacity.ColorUseRule or 0), number(text.ShadowOffset.X), number(text.ShadowOffset.Y),
        number(shadow.R), number(shadow.G), number(shadow.B), number(shadow.A),
    }
    assert(fields[2] ~= "", "subtitle font asset unavailable")
    return table.concat(fields, "|")
end

local function saveSubtitleStyle(subtitles)
    local text = "ZoneXM/style/1\n" .. describeText("speaker", subtitles.SpeakerDialogText.CommonTextObj)
        .. "\n" .. describeText("body", subtitles.TextDialog.CommonTextObj) .. "\n"
    if text == savedStyleText then return end
    local f, err = io.open(STYLE_FILE, "wb")
    if not f then error("cannot save subtitle style: " .. tostring(err)) end
    local ok, writeErr = f:write(text)
    f:close()
    assert(ok, "cannot save subtitle style: " .. tostring(writeErr))
    savedStyleText = text
    log("subtitle style saved for sessions that start without subtitles")
end

local function findStyleAsset(path, required)
    if path == "" then return nil end
    local object = StaticFindObject(path)
    if not (object and object:IsValid()) and type(LoadAsset) == "function"
            and not path:find("^/Engine/Transient") then
        object = LoadAsset(path)
    end
    if object and object:IsValid() then return object end
    assert(not required, "saved subtitle font is not loaded")
    noteStyle("saved subtitle style: optional material unavailable; using font without it")
end

local function savedTextStyle(line, role)
    local v = {}
    for field in (line .. "|"):gmatch("([^|]*)|") do v[#v + 1] = field end
    assert(#v == STYLE_FIELDS and v[1] == role, "invalid saved subtitle style")
    local function n(i) return assert(tonumber(v[i]), "invalid saved subtitle style number") end
    local function rgba(i) return { R = n(i), G = n(i + 1), B = n(i + 2), A = n(i + 3) } end
    local font = {
        FontObject = findStyleAsset(v[2], true), FontMaterial = findStyleAsset(v[3]),
        TypefaceFontName = FName(v[4]), Size = n(5), LetterSpacing = n(6),
        OutlineSettings = { OutlineSize = n(7), OutlineMaterial = findStyleAsset(v[8]), OutlineColor = rgba(9),
            bSeparateFillAlpha = v[13] == "1", bApplyOutlineToDropShadows = v[14] == "1" },
    }
    return { IsValid = function() return true end, Font = font,
        ColorAndOpacity = { SpecifiedColor = rgba(15), ColorUseRule = n(19) },
        ShadowOffset = { X = n(20), Y = n(21) }, ShadowColorAndOpacity = rgba(22) }
end

local function savedSubtitleStyle()
    local data = readSnapshot(STYLE_FILE)
    if not data then return nil end
    local speaker, body = data:match("^ZoneXM/style/1\n([^\n]+)\n([^\n]+)\n$")
    assert(speaker, "invalid saved subtitle style")
    return savedTextStyle(speaker, "speaker"), savedTextStyle(body, "body")
end

-- Only before any subtitle has ever been seen: game's default text font, subtitle-like colors.
local function fallbackStyle(r, g, b)
    return { IsValid = function() return true end,
        ColorAndOpacity = { SpecifiedColor = { R = r, G = g, B = b, A = 1 }, ColorUseRule = 0 },
        ShadowOffset = { X = 1, Y = 1 }, ShadowColorAndOpacity = { R = 0, G = 0, B = 0, A = 0.85 } }
end

local function cacheSubtitleStyle(pc)
    local subtitles = liveSubtitleView()
    if not subtitles then return end
    if not subtitleCacheValid() then
        clearSubtitleCache()
        local library = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
        local class = StaticFindObject(TEXT_WIDGET)
        assert(library and library:IsValid() and class and class:IsValid(), "subtitle cache widget class unavailable")
        styleSpeaker = library:Create(pc, class, pc)
        styleBody = library:Create(pc, class, pc)
        assert(subtitleCacheValid(), "subtitle cache widget creation failed")
        -- Viewport-owned, collapsed widgets keep full font/material UObject references
        -- alive after the game's transient SubtitleView is removed or garbage-collected.
        for _, widget in ipairs({ styleSpeaker, styleBody }) do
            widget:SetVisibility(1) -- Collapsed: no rendering, layout, or input
            widget:AddToViewport(0)
        end
        styleOwner = pc:GetAddress()
        log("subtitle styling retained for this player")
    end
    subtitleStyle(styleSpeaker.CommonTextObj, subtitles.SpeakerDialogText.CommonTextObj)
    subtitleStyle(styleBody.CommonTextObj, subtitles.TextDialog.CommonTextObj)
    local saved, saveErr = pcall(saveSubtitleStyle, subtitles)
    if not saved and tostring(saveErr) ~= styleSaveError then log("subtitle style save ERROR: " .. tostring(saveErr)) end
    styleSaveError = not saved and tostring(saveErr) or nil
end

local function bannerStyles(pc)
    local cached, cacheErr = pcall(cacheSubtitleStyle, pc)
    if not cached then noteStyle("subtitle style capture ERROR: " .. tostring(cacheErr)) end
    if subtitleCacheValid() then
        noteStyle("banner style: subtitles")
        return styleSpeaker.CommonTextObj, styleBody.CommonTextObj
    end
    local loaded, speaker, body = pcall(savedSubtitleStyle)
    if loaded and speaker then
        noteStyle("banner style: saved subtitle style (no subtitles yet this session)")
        return speaker, body
    end
    noteStyle(loaded and "banner style: fallback colors (subtitle style not captured yet; shows after anyone speaks)"
        or ("banner style: fallback colors (saved subtitle style unusable: " .. tostring(speaker) .. ")"))
    return fallbackStyle(1, 0.72, 0.1), fallbackStyle(1, 1, 1)
end

local function positionBanner(pc)
    local layout = StaticFindObject("/Script/UMG.Default__WidgetLayoutLibrary")
    assert(layout and layout:IsValid(), "viewport layout library unavailable")
    local viewport = layout:GetViewportSize(pc)
    local scale = layout:GetViewportScale(pc)
    assert(scale > 0 and scale < math.huge and viewport.X > 0 and viewport.X < math.huge
        and viewport.Y > 0 and viewport.Y < math.huge, "invalid banner viewport dimensions/DPI")
    local width, height = viewport.X / scale, viewport.Y / scale
    local insetX, insetY = math.min(64, width / 10), math.min(80, height / 10)
    local boxWidth, boxHeight = math.min(640, width - 2 * insetX), math.min(100, height - 2 * insetY)
    local titleText, bodyText = banner.CommonTextObj, bannerBody.CommonTextObj
    titleText:SetAutoWrapText(false)
    bodyText:SetAutoWrapText(false)
    banner:ForceLayoutPrepass()
    bannerBody:ForceLayoutPrepass()
    local titleWidth = titleText:GetDesiredSize().X
    local bodyWidth = bodyText:GetDesiredSize().X
    local hasBody = bodyText:GetText():ToString() ~= ""
    titleWidth = math.min(titleWidth, hasBody and boxWidth / 2 or boxWidth)
    bodyWidth = hasBody and math.min(bodyWidth, boxWidth - titleWidth) or 0
    local x, y = width - insetX - titleWidth - bodyWidth, height - insetY - boxHeight
    for _, part in ipairs({
        { widget = banner, x = x, width = titleWidth },
        { widget = bannerBody, x = x + titleWidth, width = math.max(1, bodyWidth) },
    }) do
        part.widget.CommonTextObj:SetAutoWrapText(true)
        part.widget:SetDesiredSizeInViewport({ X = part.width, Y = boxHeight })
        -- Nonzero viewport anchors read back as zero in this game.
        part.widget:SetPositionInViewport({ X = part.x, Y = y }, false)
        part.widget:SetAnchorsInViewport({ Minimum = { X = 0, Y = 0 }, Maximum = { X = 0, Y = 0 } })
        part.widget:SetAlignmentInViewport({ X = 0, Y = 0 })
    end
end

local function showBanner(pc, track, now)
    local library = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
    local class = StaticFindObject(TEXT_WIDGET)
    assert(library and library:IsValid() and class and class:IsValid(), "banner widget class unavailable")
    local speaker, dialogue = bannerStyles(pc)
    banner = library:Create(pc, class, pc)
    assert(banner and banner:IsValid(), "banner widget creation failed")
    bannerBody = library:Create(pc, class, pc)
    assert(bannerBody and bannerBody:IsValid(), "banner body creation failed")
    local title, body = bannerParts(track)
    for _, part in ipairs({
        { widget = banner, source = speaker, text = title },
        { widget = bannerBody, source = dialogue, text = body },
    }) do
        part.widget:SetVisibility(4) -- HitTestInvisible: never take mouse/game input
        part.widget:AddToViewport(10)
        part.widget:SetText(FText(part.text))
        local text = part.widget.CommonTextObj
        assert(text and text:IsValid(), "banner text block unavailable")
        text:SetJustification(0)
        subtitleStyle(text, part.source)
    end
    positionBanner(pc)
    bannerOwner, bannerAt = pc:GetAddress(), now
    bannerKey, bannerKind = track.key, track.notification
    if track.notification then lastShownNotification = track.key else lastShownTrack = track.key end
    log(track.notification and "notification banner shown" or "now-playing banner shown")
end

local function wasShown(track)
    return track.key == (track.notification and lastShownNotification or lastShownTrack)
end

local function pollBanner(now, pc)
    if now < bannerRetryAt then return end
    local ok, err = pcall(function()
        local playerValid = pc and pc:IsValid()
        if styleOwner and (not playerValid or styleOwner ~= pc:GetAddress()) then clearSubtitleCache() end
        if lastTrackRead ~= now then
            if playerValid and pc.Pawn and pc.Pawn:IsValid() and not subtitleCacheValid() then
                cacheSubtitleStyle(pc)
            end
            local notification, active, expiredKey, expiredAge = readNotification(now)
            if active then currentTrack = notification else currentTrack = readTrack(now) end
            lastTrackRead = now
            -- Metadata-only, once per event: correlates with the companion's activity log.
            if notification and notification.key ~= notedNotification then
                notedNotification = notification.key
                log(string.format("notification event received by game (age=%ds)", notification.age))
            end
            if expiredKey and expiredKey ~= lastShownNotification and expiredKey ~= notedExpired then
                notedExpired = expiredKey
                log(string.format("notification not displayed: event age %ds is outside the 30-second window", expiredAge))
            end
        end
        if not currentTrack and not banner then return end
        local ready = pc and pc:IsValid() and pc.Pawn and pc.Pawn:IsValid()
        if ready then
            local gameplay = StaticFindObject("/Script/Engine.Default__GameplayStatics")
            assert(gameplay and gameplay:IsValid(), "GameplayStatics unavailable")
            ready = not gameplay:IsGamePaused(pc)
        end
        if banner then
            local reason = not ready and "paused/no player"
                or not currentTrack and "source idle/stale"
                or bannerOwner ~= pc:GetAddress() and "player changed"
                or now - bannerAt >= BANNER_SECONDS and "six-second expiry"
                or (currentTrack.key ~= bannerKey or currentTrack.notification ~= bannerKind) and "new event/source"
            if reason then hideBanner(reason, now) end
        end
        -- Banners show during combat and dialogue too; only a paused/absent player defers them.
        if ready and currentTrack and not wasShown(currentTrack) then
            showBanner(pc, currentTrack, now)
        elseif banner then
            positionBanner(pc)
        elseif not ready and currentTrack and currentTrack.notification
                and not wasShown(currentTrack) and currentTrack.key ~= notedWaiting then
            notedWaiting = currentTrack.key
            log("notification waiting: game paused or no player")
        end
    end)
    if not ok then
        if tostring(err) ~= bannerError then log("banner ERROR: " .. tostring(err)) end
        bannerError = tostring(err)
        local removed, removeErr = pcall(hideBanner)
        if not removed then log("banner cleanup ERROR: " .. tostring(removeErr)) end
        local cleared, clearErr = pcall(clearSubtitleCache)
        if not cleared then log("subtitle cache cleanup ERROR: " .. tostring(clearErr)) end
        currentTrack, lastTrackRead = nil, nil
        bannerRetryAt = now + 10
    elseif bannerError then
        log("banner recovered")
        bannerError = nil
    end
end

local function writeFlag()
    local f = io.open(FLAG, "w")
    if f then f:write(tostring(os.time())) f:close() end
end

LoopInGameThreadWithDelay(POLL_MS, function()
    local nowMs = os.time() * 1000
    -- speech tier: subtitles render whenever anyone talks (dialogs, barks,
    -- cutscenes) — requires subtitles ON in game settings. IsInStaticDialog
    -- stayed false through a real dialog (first test) but costs nothing.
    pcall(function()
        local sv = FindFirstOf("SubtitleView")
        if sv and sv:IsValid() and sv:IsVisible() then
            lastTalkAt = nowMs
            talkCount = talkCount + 1
            if talkCount <= 3 then log("subtitles visible: someone's talking (#" .. talkCount .. ")") end
        end
    end)
    local pcAlive = false
    local pc
    pcall(function()
        pc = UEHelpers.GetPlayerController()
        pcAlive = pc and pc:IsValid() or false
        if pcAlive and pc:IsInStaticDialog() then
            lastTalkAt = nowMs
            if not dialogProbe then log("static dialog detected (queryable works)") dialogProbe = true end
        end
    end)
    -- Loading / world transition: no player controller = nothing is near Skif.
    if not pcAlive then
        lastHitAt, lastTalkAt, lastBeastAt = 0.0, 0.0, 0.0
    end
    -- lastHitAt's window IS the holdoff (the old two-layer version doubled it)
    local hot = (lastHitAt > 0 and (nowMs - lastHitAt) < HOLDOFF_MS)
        or (lastTalkAt > 0 and (nowMs - lastTalkAt) < TALK_HOLDOFF_MS)
        or (lastBeastAt > 0 and (nowMs - lastBeastAt) < BEAST_HOLDOFF_MS)
    if hot then
        -- beat stamp only on actual writes, else the heartbeat never fires
        if not written or nowMs - lastBeatAt >= HEARTBEAT_MS then
            writeFlag()
            lastBeatAt = nowMs
            if not written then writes = writes + 1 end
        end
    elseif written then
        pcall(os.remove, FLAG)
        writes = writes + 1
    end
    if writes <= 4 and hot ~= written then log("alert -> " .. (hot and "DANGER" or "clear")) end
    written = hot
    pollBanner(os.time(), pc)
    return false
end)

log("loaded (flag: " .. FLAG .. ")")
