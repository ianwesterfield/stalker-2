local root = arg[1] or "Gaming/stalker-2"
local modFolders = { MolotovFire = "molotov-cocktail", ZoneXM = "zonexm" }

local function loadMod(name, exports)
    local state = { timers = {}, delayed = {}, queue = {}, logs = {}, reads = 0, violations = 0 }
    local function objectRead()
        state.reads = state.reads + 1
        if not state.onGameThread then state.violations = state.violations + 1 end
    end
    local function forbidden()
        error("Async scheduling is forbidden in these mods")
    end
    state.env = setmetatable({
        print = function(message) state.logs[#state.logs + 1] = message end,
        require = function(name)
            assert(name == "UEHelpers")
            return { GetPlayerController = function() objectRead(); return state.controller end }
        end,
        RegisterHook = function() end,
        RegisterKeyBind = function(key, callback)
            if key == "LEFT_MOUSE_BUTTON" then state.click = callback end
        end,
        Key = { LEFT_MOUSE_BUTTON = "LEFT_MOUSE_BUTTON" }, ModifierKey = {},
        LoopAsync = forbidden, ExecuteWithDelay = forbidden, ExecuteAsync = forbidden,
        LoopInGameThreadWithDelay = function(delay, callback)
            state.timers[#state.timers + 1] = { delay = delay, callback = callback }
            return #state.timers
        end,
        CancelDelayedAction = function(handle)
            assert(state.timers[handle], "Unknown timer handle")
            state.timers[handle].cancelled = true
            return true
        end,
        ExecuteInGameThreadWithDelay = function(delay, callback)
            state.delayed[#state.delayed + 1] = callback
            return #state.delayed
        end,
        ExecuteInGameThread = function(callback) state.queue[#state.queue + 1] = callback end,
        FindAllOf = function() objectRead(); return {} end,
        FindFirstOf = function() objectRead(); return nil end,
        StaticFindObject = function() objectRead(); return nil end,
        io = { open = function(_, mode)
            if mode == "rb" then return nil, "not found", 2 end
            error("Unexpected flag write")
        end },
    }, { __index = _G })
    local path = root .. "/mods/" .. modFolders[name] .. "/ue4ss/" .. name .. "/Scripts/main.lua"
    local file = assert(io.open(path))
    local source = file:read("*a")
    file:close()
    state.exports = assert(load(source .. "\n" .. (exports or ""), "@" .. path, "t", state.env))()
    function state:run(callback)
        self.onGameThread = true
        local ok, result = pcall(callback)
        self.onGameThread = false
        assert(ok, result)
        return result
    end
    function state:drain(field)
        local ready = self[field]
        self[field] = {}
        for _, callback in ipairs(ready) do self:run(callback) end
    end
    function state:check()
        assert(self.violations == 0, "UObject read outside game thread")
        for _, message in ipairs(self.logs) do
            assert(not message:find("ERR"), message)
        end
    end
    return state
end

local molotovExports = [[
return { douse = douseRagFire, restore = fpRestore, fp = fp, mp = mp,
    injectCraft = injectCraftEntry, craftSelection = craftSelection, menuCraft = menuCraft,
    setCraftFire = function(callback) craftFire = callback end,
    physics = kickRagPhysics, fire = ragFire, currentMesh = currentRagMesh,
    disableHoldBurn = function() HOLD_BURN_ENABLED = false end,
    expireQuietBanners = function() QUIET_BANNERS = true; quietBanners(-1) end }
]]

local molotov = loadMod("MolotovFire", molotovExports)
assert(#molotov.timers == 9)
assert(molotov.reads == 0)
for pass = 1, 3 do
    for _, timer in ipairs(molotov.timers) do
        assert(molotov:run(timer.callback) == false)
    end
    molotov:drain("queue")
end
molotov:check()
print("PASS: MolotovFire native timers and idle callbacks")

molotov.exports.disableHoldBurn()
for _, timer in ipairs(molotov.timers) do
    if timer.delay == 1500 then
        molotov:run(timer.callback)
        assert(timer.cancelled, "Disabled hold-burn timer was not cancelled")
    end
end
molotov.exports.expireQuietBanners()
local quietTimer = molotov.timers[#molotov.timers]
assert(quietTimer.delay == 200)
molotov:run(quietTimer.callback)
assert(quietTimer.cancelled, "Expired banner timer was not cancelled")
print("PASS: finite native timers use explicit handle cancellation")

for _, cleanup in ipairs({ "douse", "restore" }) do
    for _, alreadyQueued in ipairs({ false, true }) do
        local state = loadMod("MolotovFire", molotovExports)
        local api = state.exports
        local touches = 0
        local anim = { IsValid = function() touches = touches + 1; return true end }
        api.physics(anim, 1)
        api.fire(anim, 1)
        if alreadyQueued then state:drain("delayed") end
        state:run(function() api[cleanup]("test") end)
        if not alreadyQueued then state:drain("delayed") end
        state:drain("queue")
        assert(touches == 0, "Cancelled retry touched its captured object")
        assert(#state.delayed == 0, "Cancelled retry rescheduled itself")
        state:check()
    end
end
print("PASS: douse and restore cancel retries before and after queueing")

local api = molotov.exports
local destroyed = 0
local component = {
    IsValid = function() return true end,
    Deactivate = function() end,
    K2_DestroyComponent = function() destroyed = destroyed + 1 end,
}
api.fp.rag, api.fp.ragLower = component, { component }
api.mp.cur = { wpn = {}, body = {} }
molotov:run(function() api.douse("test") end)
molotov:drain("queue")
assert(api.fp.rag == nil and api.fp.ragLower == nil)
assert(next(api.mp.cur) == nil and molotov.env.mp == nil)
assert(destroyed == 2)
molotov:check()
print("PASS: douse clears components and the local montage state")

local mesh = { IsValid = function() return true end }
local anim = {
    IsValid = function() return true end,
    GetAddress = function() return 1 end,
    GetOwningComponent = function() return mesh end,
}
mesh.AnimScriptInstance = { IsValid = function() return true end, GetAddress = function() return 2 end }
molotov.env.StaticFindObject = function()
    return {
        IsValid = function() return true end,
        GetPlayerItemInHandsData = function() return { MainHandItemPrototypeID = "GrenadeMolotov" } end,
    }
end
assert(molotov:run(function() return api.currentMesh(anim) end) == nil)
mesh.AnimScriptInstance = anim
assert(molotov:run(function() return api.currentMesh(anim) end) == mesh)
print("PASS: pooled mesh rejects a replaced animation instance")

local craft = loadMod("MolotovFire", molotovExports)
local function craftObject(address)
    return {
        IsValid = function() return true end,
        IsVisible = function() return true end,
        GetAddress = function() return address end,
        GetFullName = function() return "TestObject" end,
    }
end
local menu, inventory, slot = craftObject(10), craftObject(20), craftObject(30)
inventory.CurrClickedItem, inventory.RightClickMenuWidget = slot, menu
local image, wrapper, material = craftObject(40), craftObject(50), craftObject(60)
slot.ItemImage, wrapper.ImageObj, image.Brush = wrapper, image, { ResourceObject = material }
local iconName = "T_cns_cossacks_vodka_01"
local texture = craftObject(70)
texture.GetFullName = function()
    return "Texture2D /Game/GameLite/FPS_Game/UIRemaster/UITextures/Inventory/Consumable/"
        .. iconName .. "." .. iconName
end
material.TextureParameterValues = { ForEach = function(_, callback)
    callback(1, { get = function()
        return { ParameterInfo = { Name = { ToString = function() return "Icon" end } },
            ParameterValue = texture }
    end })
end }
craft.env.FindAllOf = function(class) return class == "InventoryNew" and { inventory } or {} end
local vodka, bandages, rows, crafts, removedRows = 1, 1, 0, 0, 0
local mediator = craftObject(80)
mediator.GetItemsCountInInventory = function(_, _, item)
    return item == "Vodka" and vodka or bandages
end
craft.controller = { Pawn = craftObject(90) }
craft.env.FText = function(text) return text end
menu.MenuItemWidgetClass, menu.Menu = {}, craftObject(100)
menu.Menu.AddChild = function() rows = rows + 1 end
inventory.HideRightClickMenu = function() end
craft.env.StaticFindObject = function(path)
    if path == "/Script/Stalker2.Default__CppMediator" then return mediator end
    assert(path == "/Script/UMG.Default__WidgetBlueprintLibrary")
    return { Create = function()
        local row = craftObject(110)
        row.Label = { SetText = function() end }
        row.IsHovered = function() return true end
        row.OnButtonUnHovered, row.OnButtonHovered = function() end, function() end
        row.RemoveFromParent = function() removedRows = removedRows + 1 end
        return row
    end }
end
craft.exports.setCraftFire(function(_, sid, done)
    assert(sid == "MolotovCraft_TakeVodka")
    crafts = crafts + 1
    done()
end)
local function inject()
    craft:run(function() craft.exports.injectCraft(menu) end)
end
local function click()
    craft.click()
    craft:drain("queue")
end
for _, ingredient in ipairs({ "T_cns_cossacks_vodka_01", "T_cns_bandage_01" }) do
    iconName = ingredient
    inject()
    assert(craft.exports.menuCraft.entry, "Ingredient must receive a craft row")
    click()
end
assert(rows == 2 and crafts == 2 and removedRows == 2)
for _, other in ipairs({ "T_cns_pills_03", "T_cns_food_01", "T_cns_bandage_01_custom" }) do
    iconName = other
    inject()
    assert(not craft.exports.menuCraft.entry, "Unrelated item received a craft row")
end
iconName = "T_cns_bandage_01"
vodka = 0; inject(); vodka = 1
bandages = 0; inject(); bandages = 1
assert(rows == 2, "Missing ingredients must suppress the row")
inject()
vodka = 0; click(); vodka = 1
assert(crafts == 2, "Click must recheck ingredient counts")
inject()
iconName = "T_cns_pills_03"; click()
assert(crafts == 2 and not craft.exports.menuCraft.entry, "Stale selection crafted")
iconName = "T_cns_bandage_01"; inject()
inventory.RightClickMenuWidget = craftObject(999)
click()
assert(crafts == 2, "Stale menu crafted")
inject()
assert(not craft.exports.menuCraft.entry, "Unrelated menu received a row")
inventory.RightClickMenuWidget = menu
inventory.CurrClickedItem = nil
inject()
assert(not craft.exports.menuCraft.entry)
assert(craft.logs[#craft.logs]:find("selection unavailable"), "Missing selection must be logged")
inventory.CurrClickedItem = slot
image.Brush.ResourceObject = nil
inject()
assert(not craft.exports.menuCraft.entry)
image.Brush.ResourceObject = material
inject()
slot.GetAddress = function() return 31 end
for _, timer in ipairs(craft.timers) do
    if timer.delay == 60 then craft:run(timer.callback) end
end
craft:drain("queue")
assert(not craft.exports.menuCraft.entry, "Reused menu retained a stale row")
menu.IsVisible = function() return false end
inject()
assert(not craft.exports.menuCraft.entry, "Closed menu received a row")
craft:check()
print("PASS: crafting requires selected vodka/bandage, ingredients, and the current visible menu")

local zone = loadMod("ZoneXM", "return { pollBanner = pollBanner, readTrack = readTrack, readNotification = readNotification, bannerLine = bannerLine, bannerText = bannerText }")
assert(#zone.timers == 2 and zone.reads == 0)
zone.controller = {
    IsValid = function() return true end,
    IsInStaticDialog = function() return false end,
    Pawn = {
        IsValid = function() return true end,
        K2_GetActorLocation = function() return { X = 0, Y = 0, Z = 0 } end,
    },
}
for _, timer in ipairs(zone.timers) do assert(zone:run(timer.callback) == false) end
assert(zone.reads > 0)
zone:check()
print("PASS: ZoneXM polls Unreal objects on native game-thread timers")

local snapshot, notificationSnapshot, styleSnapshot, paused, created, removed = nil, nil, nil, false, {}, 0
zone.controller.GetAddress = function() return 123 end
zone.env.FText = function(text) return text end
zone.env.FName = function(text) return text end
local function openSnapshot(path, mode)
    if path:match("subtitle%-style%.txt$") then
        if mode == "wb" then
            local buffer = {}
            return { write = function(self, text) buffer[#buffer + 1] = text return self end,
                close = function() styleSnapshot = table.concat(buffer) end }
        end
        assert(mode == "rb")
        if not styleSnapshot then return nil, "not found", 2 end
        return { read = function(_, count) return styleSnapshot:sub(1, count) end, close = function() end }
    end
    assert(mode == "rb")
    local data = snapshot
    if path:match("notification%.txt$") then data = notificationSnapshot end
    if not data then return nil, "not found", 2 end
    return { read = function(_, count) return data:sub(1, count) end, close = function() end }
end
zone.env.io.open = openSnapshot
local function noop() end
local function valid() return true end
local assets = {}
local function asset(class, path)
    local object = { IsValid = valid, GetFullName = function() return class .. " " .. path end }
    assets[path] = object
    return object
end
local subtitleFont = asset("Font", "/Game/UI/Fonts/Subtitle.Subtitle")
local speakerMaterial = asset("MaterialInstanceConstant", "/Game/UI/Materials/MI_Speaker.MI_Speaker")
local bodyMaterial = asset("MaterialInstanceConstant", "/Game/UI/Materials/MI_Body.MI_Body")
local speakerOutline = asset("MaterialInstanceConstant", "/Game/UI/Materials/MI_SpeakerOutline.MI_SpeakerOutline")
local bodyOutline = asset("MaterialInstanceConstant", "/Game/UI/Materials/MI_BodyOutline.MI_BodyOutline")
local viewport, viewportScale = { X = 3440, Y = 1440 }, 4 / 3
local speakerStyle = {
    IsValid = valid, Font = { Size = 20, FontObject = subtitleFont, FontMaterial = speakerMaterial,
        TypefaceFontName = "Bold", LetterSpacing = 2,
        OutlineSettings = { OutlineSize = 1, OutlineMaterial = speakerOutline,
            bApplyOutlineToDropShadows = true, OutlineColor = { R = 0, G = 0, B = 0, A = 1 } } },
    ColorAndOpacity = { SpecifiedColor = { R = 1, G = 0.55, B = 0, A = 1 } },
    ShadowOffset = { X = 1, Y = 1 }, ShadowColorAndOpacity = { R = 0, G = 0, B = 0, A = 1 },
}
local bodyStyle = {
    IsValid = valid, Font = { Size = 20, FontObject = subtitleFont, FontMaterial = bodyMaterial,
        TypefaceFontName = "Bold", LetterSpacing = 2,
        OutlineSettings = { OutlineSize = 1, OutlineMaterial = bodyOutline,
            bApplyOutlineToDropShadows = true, OutlineColor = { R = 0, G = 0, B = 0, A = 1 } } },
    ColorAndOpacity = { SpecifiedColor = { R = 1, G = 1, B = 1, A = 1 }, ColorUseRule = 0 },
    ShadowOffset = { X = 1, Y = 1 }, ShadowColorAndOpacity = { R = 0, G = 0, B = 0, A = 1 },
}
local subtitleView = { IsValid = valid, SpeakerDialogText = { IsValid = valid, CommonTextObj = speakerStyle },
    TextDialog = { IsValid = valid, CommonTextObj = bodyStyle } }
local subtitleCandidates = {}
zone.env.FindAllOf = function(class)
    assert(zone.onGameThread and class == "SubtitleView")
    return subtitleCandidates
end
zone.env.FindFirstOf = function(class)
    assert(zone.onGameThread)
    assert(class == "SubtitleView")
    return subtitleView
end
local creatingBody = false
local styleHolders = {}
zone.env.StaticFindObject = function(path)
    assert(zone.onGameThread)
    if path:find("GameplayStatics") then return { IsValid = valid, IsGamePaused = function() return paused end } end
    if path:find("WidgetLayoutLibrary") then
        return { IsValid = valid, GetViewportSize = function() return viewport end,
            GetViewportScale = function() return viewportScale end }
    end
    if path:find("WidgetBlueprintLibrary") then
        return { IsValid = valid, Create = function(_, pc)
            assert(pc == zone.controller)
            local isBody = creatingBody
            creatingBody = not creatingBody
            local titleWidget = isBody and created[#created] or nil
            local widget = {
                IsValid = valid, AddToViewport = noop, ForceLayoutPrepass = noop,
                SetAnchorsInViewport = function(self)
                    self.anchors = { Minimum = { X = 0, Y = 0 }, Maximum = { X = 0, Y = 0 } }
                end,
                SetAlignmentInViewport = function(self, alignment) self.alignment = alignment end,
                SetPositionInViewport = function(self, position, removeDpi)
                    self.position, self.removeDpi = position, removeDpi
                    self.anchors = nil
                end,
                SetDesiredSizeInViewport = function(self, size) self.size = size end,
                SetVisibility = function(self, visibility)
                    assert(visibility == 4 or visibility == 1)
                    if visibility == 1 then
                        self.styleHolder = true
                        styleHolders[#styleHolders + 1] = self
                        if not isBody then
                            assert(created[#created] == self)
                            table.remove(created)
                        end
                    end
                end,
                SetText = function(self, text)
                    self.partText = text
                    self.text = text
                    self.CommonTextObj.value = text
                    if titleWidget then titleWidget.text = titleWidget.partText .. text end
                end,
                RemoveFromParent = function(self)
                    self.removed = true
                    if not isBody and not self.styleHolder then removed = removed + 1 end
                end,
                CommonTextObj = {
                    IsValid = valid, SetAutoWrapText = noop,
                    Font = { Size = 18 },
                    SetFont = function(self, font) self.Font = font end,
                    SetJustification = function(self, value) self.justification = value end,
                    SetColorAndOpacity = function(self, value) self.ColorAndOpacity = value end,
                    SetShadowOffset = function(self, value) self.ShadowOffset = value end,
                    SetShadowColorAndOpacity = function(self, value) self.ShadowColorAndOpacity = value end,
                    GetDesiredSize = function(self) return { X = #(self.value or "") * 10, Y = 24 } end,
                    GetText = function(self) return { ToString = function() return self.value or "" end } end,
                },
            }
            if isBody then titleWidget.body = widget else created[#created + 1] = widget end
            return widget
        end }
    end
    if path:find("^/Game/UI/") then return assets[path] end
    assert(path:find("W_Text"), "Unexpected widget class")
    return { IsValid = valid }
end
local function track(now, title, artist, source)
    snapshot = string.format("ZoneXM/1\n%d\n%s\n%s\n%s\n", now, source or "Pandora", title or "", artist or "")
end
local function poll(now, pc)
    zone:run(function() zone.exports.pollBanner(now, pc or zone.controller) end)
end
track(100, "First song", "Artist")
poll(100)
assert(#created == 1 and created[1].text == "Artist - First song")
local layout = created[1]
assert(layout.position.X == 2326 and layout.position.Y == 900 and layout.removeDpi == false)
assert(layout.anchors.Minimum.X == 0 and layout.anchors.Minimum.Y == 0
    and layout.anchors.Maximum.X == 0 and layout.anchors.Maximum.Y == 0)
assert(layout.alignment.X == 0 and layout.alignment.Y == 0
    and layout.size.X == 60 and layout.size.Y == 100)
assert(layout.partText == "Artist" and layout.body.partText == " - First song")
assert(layout.CommonTextObj.Font == speakerStyle.Font and layout.CommonTextObj.ColorAndOpacity == speakerStyle.ColorAndOpacity)
assert(layout.body.CommonTextObj.Font == bodyStyle.Font and layout.body.CommonTextObj.ColorAndOpacity == bodyStyle.ColorAndOpacity)
assert(layout.CommonTextObj.Font.FontMaterial == speakerMaterial
    and layout.body.CommonTextObj.Font.FontMaterial == bodyMaterial
    and layout.CommonTextObj.Font.OutlineSettings.OutlineMaterial == speakerOutline
    and layout.body.CommonTextObj.Font.OutlineSettings.OutlineMaterial == bodyOutline
    and layout.body.CommonTextObj.Font.OutlineSettings.bApplyOutlineToDropShadows
    and layout.CommonTextObj.Font.TypefaceFontName == "Bold"
    and layout.CommonTextObj.Font.LetterSpacing == 2, "Subtitle font materials/outline/spacing were lost")
assert(layout.CommonTextObj.ShadowOffset == speakerStyle.ShadowOffset
    and layout.body.CommonTextObj.ShadowColorAndOpacity == bodyStyle.ShadowColorAndOpacity)
assert(speakerStyle.Font.Size == 20 and bodyStyle.Font.Size == 20, "Live subtitle style was modified")
assert(layout.CommonTextObj.justification == 0 and layout.body.CommonTextObj.justification == 0)
for _, dimensions in ipairs({ { 1920, 1080, 1 }, { 3840, 2160, 2 }, { 800, 600, 1 }, { 400, 300, 2 } }) do
    viewport, viewportScale = { X = dimensions[1], Y = dimensions[2] }, dimensions[3]
    poll(100)
    local w, h = viewport.X / viewportScale, viewport.Y / viewportScale
    assert(math.abs(layout.body.position.X + layout.body.size.X - (w - math.min(64, w / 10))) < 0.001)
    assert(layout.position.X + layout.size.X == layout.body.position.X, "Subtitle segments overlap or gap")
    assert(math.abs(layout.position.Y + layout.size.Y - (h - math.min(80, h / 10))) < 0.001)
    assert(layout.position.X >= 0 and layout.position.Y >= 0
        and layout.position.X + layout.size.X <= w and layout.position.Y + layout.size.Y <= h,
        "Banner extends outside DPI-scaled viewport")
end
assert(#created == 1, "Resize recreated or repeated the banner")
viewport, viewportScale = { X = 3440, Y = 1440 }, 4 / 3
track(101, "First song", "Artist")
poll(101)
assert(#created == 1, "Heartbeat repeated a banner")
poll(106)
assert(removed == 1, "Banner did not expire after six seconds")
assert(layout.removed and layout.body.removed, "Subtitle segments not both removed")
assert(zone.logs[#zone.logs]:find("banner dismissed: six%-second expiry, age=6s"),
    "Banner lifetime diagnostic missing")
poll(107)
assert(#created == 1)
track(108, "Latest song", "Other artist", "iTunes")
poll(108)
assert(#created == 2 and created[2].text:find("Latest song"), "Banner was suppressed during danger/dialogue")
poll(109)
assert(#created == 2 and removed == 1, "Banner repeated or was dismissed early")
poll(110)
track(111, "", "", "")
poll(111)
assert(removed == 2, "Paused/absent media left its banner visible")
track(112, "Latest song", "Other artist", "iTunes")
poll(112)
assert(#created == 2, "Resume repeated the same song")
track(113, "No artist", "", "AppleMusic")
paused = true
poll(113)
assert(#created == 2)
paused = false
poll(114)
assert(#created == 3 and created[3].text == "No artist")
poll(115, { IsValid = function() return false end })
assert(removed == 3, "World transition left its banner visible")
track(100, "Stale song")
poll(116)
track(130, "Future song")
poll(117)
assert(#created == 3, "Stale/future metadata was displayed")
snapshot = nil
poll(118)
track(119, "New world song")
poll(119)
assert(#created == 4)
track(120, "Replaced song")
poll(120)
assert(#created == 5 and removed == 4, "New song stacked instead of replacing")
zone:check()
print("PASS: app-agnostic banners, deduplication, expiry, pause, danger, and world transitions")

for _, bad in ipairs({
    "", "ZoneXM/2\n100\nsource\ntitle\nartist\n", "ZoneXM/1\n100\nsource\ntitle\n",
    string.rep("a", 4097), "ZoneXM/1\n100\nsource\ntitle\0\nartist\n",
    "ZoneXM/1\n100\nsource\n\255\nartist\n",
}) do
    snapshot = bad
    assert(not pcall(zone.exports.readTrack, 100), "Malformed snapshot accepted")
end
snapshot = "bad snapshot"
poll(121)
local errorLogged = false
for _, message in ipairs(zone.logs) do if message:find("banner ERROR") then errorLogged = true end end
assert(errorLogged, "Invalid input was not logged")
track(131, "Recovered song")
poll(131)
assert(#created == 6, "Banner did not recover after malformed input")
print("PASS: bounded UTF-8 protocol rejects malformed input and recovers with logged errors")
local unicodeTitle = string.rep(utf8.char(0x1F3B5), 81)
assert(zone.exports.bannerLine(unicodeTitle) == string.rep(utf8.char(0x1F3B5), 80) .. "...")
zone.env.io.open = function() return nil, "permission denied", 13 end
assert(not pcall(zone.exports.readTrack, 132), "Read failure was hidden as absent media")
print("PASS: display truncation preserves Unicode; file access errors are surfaced")

zone.env.io.open = openSnapshot
local function notification(now, received, id, title, body, app)
    notificationSnapshot = string.format("ZoneXM/notification/1\n%d\n%d\nApp.Id\n%s\n%s\n%s\n%s\n",
        now, received, id, app or "Pandora", title or "Notification", body or "Body")
end
track(140, "Media should not win")
notification(140, 140, "event1", "Song title", "Artist")
poll(140)
assert(#created == 7 and created[7].text == "Song title - Artist")
notification(141, 140, "event1", "Song title", "Artist")
poll(141)
assert(#created == 7, "Notification heartbeat repeated a banner")
notification(142, 142, "event2", "Song title", "Artist")
poll(142)
assert(#created == 8, "Identical text with a new event ID was lost")
notification(143, 143, "event4", "Latest", "Newest only", "Calendar")
local beforeReceipt = #zone.logs
poll(143)
assert(#created == 9 and created[9].text == "Latest - Newest only", "Notification was suppressed during danger/dialogue")
local receiptLogged = false
for i = beforeReceipt + 1, #zone.logs do
    assert(not zone.logs[i]:find("Latest") and not zone.logs[i]:find("Newest"), "Diagnostic leaked notification contents")
    if zone.logs[i]:find("notification event received by game %(age=0s%)") then receiptLogged = true end
end
assert(receiptLogged, "Event receipt diagnostic missing")
notification(144, 144, "event5", "Paused", "Waiting")
paused = true
poll(144)
assert(#created == 9 and zone.logs[#zone.logs]:find("notification waiting: game paused or no player"),
    "Paused notification wait was not diagnosed")
local waitLogs = #zone.logs
poll(145)
assert(#zone.logs == waitLogs, "Waiting diagnostic repeated every poll")
notification(175, 144, "event5", "Paused", "Waiting")
poll(175)
assert(zone.logs[#zone.logs]:find("notification not displayed: event age 31s is outside the 30%-second window")
    and not zone.logs[#zone.logs]:find("Paused"), "Expired notification was not diagnosed")
paused = false
notification(180, 143, "event4", "Latest", "Newest only", "Calendar")
track(180, "Suppressed by live idle companion")
poll(180)
assert(#created == 9, "Expired notification or media was shown while companion owns banners")
notificationSnapshot = "ZoneXM/notification/1\n181\n0\n\n\n\n\n\n"
track(181, "Still suppressed")
poll(181)
assert(#created == 9, "Empty live companion did not suppress duplicate media")
track(190, "Media after companion exit")
poll(190)
assert(#created == 10 and created[10].text:find("Media after companion exit"), "Stale companion blocked media fallback")
notificationSnapshot = "ZoneXM/notification/1\n191\n191\napp\nid\nname\ntitle\n"
assert(not pcall(zone.exports.readNotification, 191), "Truncated notification was accepted")
track(192, "Media after companion exit")
notification(192, 192, "event5", "Temporary", "Notification")
poll(192)
assert(#created == 11)
local removedBeforeFallback = removed
notificationSnapshot = nil
poll(193)
assert(#created == 11 and removed == removedBeforeFallback + 1,
    "Returning to an already-shown media track left the notification widget visible")
assert(zone.exports.bannerText({ title = "Title only", artist = "", notification = true }) == "Title only")
assert(zone.exports.bannerText({ title = "Title", artist = "Body", notification = true }) == "Title - Body")
notificationSnapshot = "ZoneXM/notification/1\n193\n193\nPandoraMediaInc.29680B314EFC2_n619g4d5j0fnw!App\npandora-test\nPandora\nRock With Me\nRebelution\n"
local pandoraTrack = zone.exports.readNotification(193)
assert(zone.exports.bannerText(pandoraTrack) == "Rebelution - Rock With Me")
local unchangedKey = pandoraTrack.key
pandoraTrack.artist = ""
assert(zone.exports.bannerText(pandoraTrack) == "Rock With Me" and pandoraTrack.key == unchangedKey)
assert(not zone.exports.bannerText({ title = "Title", artist = "Body", notification = true }):find("\n"))
print("PASS: bottom-right layout, prefix-free formatting, Pandora artist order, event IDs, and media fallback")
notificationSnapshot = nil
track(194, "Invalid viewport test")
viewportScale = 0
poll(194)
assert(zone.logs[#zone.logs - 1]:find("invalid banner viewport") or zone.logs[#zone.logs]:find("invalid banner viewport"),
    "Invalid viewport was not surfaced")
viewportScale = 4 / 3
track(204, "Viewport recovered")
poll(204)
assert(created[#created].text == "Viewport recovered", "Viewport failure did not recover")
print("PASS: measured DPI-aware positioning, live resize, narrow viewports, invalid-DPI diagnostics and recovery")
local savedSubtitles = subtitleView
subtitleView = nil
track(211, "Missing style")
local beforeMissingStyle = #created
poll(211)
assert(#created == beforeMissingStyle + 1, "Transient subtitle removal blocked the banner")
assert(created[#created].CommonTextObj.Font == speakerStyle.Font
    and created[#created].CommonTextObj.ShadowOffset == speakerStyle.ShadowOffset
    and created[#created].body.CommonTextObj.Font == bodyStyle.Font,
    "Retained style lost original font/material/shadow data")
subtitleView = savedSubtitles
local largeFont = asset("Font", "/Game/UI/Fonts/SubtitleLarge.SubtitleLarge")
for _, style in ipairs({ speakerStyle, bodyStyle }) do
    local font = {}
    for key, value in pairs(style.Font) do font[key] = value end
    font.Size, font.FontObject = 26, largeFont
    style.Font = font
end
track(221, "New subtitle setting", "Band")
poll(221)
local styled = created[#created]
assert(styled.CommonTextObj.Font.Size == 26 and styled.body.CommonTextObj.Font.Size == 26,
    "New banner did not pick up current subtitle font size")
assert(styled.CommonTextObj.ColorAndOpacity == speakerStyle.ColorAndOpacity
    and styled.body.CommonTextObj.ColorAndOpacity == bodyStyle.ColorAndOpacity)
poll(227)
assert(styled.removed and styled.body.removed)
assert(styleSnapshot and styleSnapshot:find("/Game/UI/Fonts/SubtitleLarge.SubtitleLarge|", 1, true)
    and styleSnapshot:find("|26|", 1, true), "Changed subtitle style was not persisted")
for _, text in ipairs({ "New subtitle setting", "Band", "Missing style", "Latest", "Rebelution" }) do
    assert(not styleSnapshot:find(text, 1, true), "Saved style leaked banner text")
end
print("PASS: subtitle font/size, separate speaker/body colors, read-only style copying, missing-style diagnostics and recovery")
subtitleView = { IsValid = function() return false end }
savedSubtitles.GetFullName = function() return "SubtitleView live" end
subtitleCandidates = { savedSubtitles }
track(230, "Second live subtitle view")
poll(230)
assert(created[#created].text == "Second live subtitle view", "Invalid first subtitle view hid a live candidate")
subtitleCandidates = {}
subtitleView = nil
for _, holder in ipairs(styleHolders) do holder.IsValid = function() return false end end
local function assertSavedStyle(widget, message)
    local font, bodyFont = widget.CommonTextObj.Font, widget.body.CommonTextObj.Font
    assert(font ~= speakerStyle.Font and font.FontObject == largeFont and font.Size == 26
        and font.FontMaterial == speakerMaterial and font.OutlineSettings.OutlineMaterial == speakerOutline
        and font.OutlineSettings.bApplyOutlineToDropShadows and font.TypefaceFontName == "Bold"
        and font.LetterSpacing == 2 and bodyFont.FontMaterial == bodyMaterial, message)
    local color = widget.CommonTextObj.ColorAndOpacity.SpecifiedColor
    assert(color.R == 1 and color.G == 0.55 and color.B == 0
        and widget.body.CommonTextObj.ColorAndOpacity.SpecifiedColor.G == 1
        and widget.CommonTextObj.ShadowOffset.X == 1, message)
end
track(237, "Collected cache")
local beforeCollected = #created
poll(237)
assert(#created == beforeCollected + 1, "Collected styles blocked the banner")
assertSavedStyle(created[#created], "Collected style holder was reused instead of the saved style")
assert(zone.logs[#zone.logs - 1]:find("banner style: saved subtitle style"), "Saved style use was not logged")
subtitleView = savedSubtitles
track(247, "Cache rebuilt")
poll(247)
assert(created[#created].text == "Cache rebuilt", "Style cache failed to rebuild")
assert(created[#created].CommonTextObj.Font == speakerStyle.Font, "Live subtitles did not take priority over saved style")
local lastHolder = styleHolders[#styleHolders]
subtitleView = nil
zone.controller.GetAddress = function() return 987 end
track(254, "New player without styles")
poll(254)
assert(lastHolder.removed, "Player transition retained old viewport style holders")
assert(created[#created].text == "New player without styles", "Fresh load without subtitles blocked the banner")
assertSavedStyle(created[#created], "Old-world style holders were reused")
subtitleView = savedSubtitles
track(264, "New world styled")
poll(264)
assert(created[#created].text == "New world styled")
print("PASS: retained styles survive missing SubtitleView; invalid-first lookup, GC, and player transitions recover safely")
subtitleView = nil
zone.controller.GetAddress = function() return 989 end
local goodStyle = styleSnapshot
assets["/Game/UI/Materials/MI_Speaker.MI_Speaker"] = nil
track(266, "Optional material unloaded")
poll(266)
assert(created[#created].text == "Optional material unloaded"
    and created[#created].CommonTextObj.Font.FontObject == largeFont
    and created[#created].CommonTextObj.Font.FontMaterial == nil, "Missing optional material blocked saved style")
assets["/Game/UI/Materials/MI_Speaker.MI_Speaker"] = speakerMaterial
local function assertFallback(now, text, reason)
    track(now, text)
    poll(now)
    local widget = created[#created]
    assert(widget.text == text, "Fallback did not display the banner: " .. reason)
    assert(widget.CommonTextObj.Font.Size == 18 and widget.CommonTextObj.ColorAndOpacity.SpecifiedColor.B == 0.1
        and widget.body.CommonTextObj.ColorAndOpacity.SpecifiedColor.B == 1, "Fallback colors wrong: " .. reason)
    local logged = false
    for i = #zone.logs - 2, #zone.logs do
        if zone.logs[i] and zone.logs[i]:find(reason, 1, true) then logged = true end
    end
    assert(logged, "Fallback reason not logged: " .. reason)
end
styleSnapshot = nil
assertFallback(268, "Cold start", "subtitle style not captured yet")
styleSnapshot = "ZoneXM/style/1\nspeaker|broken\nbody|broken\n"
assertFallback(270, "Corrupt style", "saved subtitle style unusable")
styleSnapshot = goodStyle
assets["/Game/UI/Fonts/SubtitleLarge.SubtitleLarge"] = nil
assertFallback(272, "Missing font", "saved subtitle font is not loaded")
zone.env.LoadAsset = function(path)
    assert(zone.onGameThread and path == "/Game/UI/Fonts/SubtitleLarge.SubtitleLarge")
    return largeFont
end
track(274, "Font loaded on demand")
poll(274)
assert(created[#created].text == "Font loaded on demand"
    and created[#created].CommonTextObj.Font.FontObject == largeFont, "Unloaded saved font was not loaded")
zone.env.LoadAsset = nil
assets["/Game/UI/Fonts/SubtitleLarge.SubtitleLarge"] = largeFont
subtitleView = savedSubtitles
print("PASS: saved subtitle style covers fresh loads; optional materials degrade; cold/corrupt/missing-font fall back visibly")
snapshot = nil
zone.controller.GetAddress = function() return 988 end
poll(280)
local idleHolders = #styleHolders
assert(styleHolders[idleHolders].styleHolder, "Idle poll did not retain subtitle styles")
poll(281)
assert(#styleHolders == idleHolders, "Idle polls recreated valid style holders")
subtitleView = nil
track(282, "First event after dialogue disappeared", "Artist")
poll(282)
assert(#styleHolders == idleHolders, "Danger invalidated retained subtitle styles")
track(283, "First event after dialogue disappeared", "Artist")
poll(283)
assert(created[#created].text == "Artist - First event after dialogue disappeared",
    "Banner could not use styles captured before the first notification")
assert(created[#created].CommonTextObj.Font == speakerStyle.Font, "Retained live style lost priority")
print("PASS: idle style capture survives dialogue ending and combat deferral without widget churn")