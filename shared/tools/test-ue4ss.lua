local root = arg[1] or "Gaming/stalker-2"
local modFolders = {
    MolotovFire = "molotov-cocktail",
    ZoneAtlas = "zoneatlas",
    ZoneCodex = "zonecodex",
    ZoneXM = "zonexm",
}
local nativeOpen = io.open

local function loadMod(name, exports, configure)
    local state = { timers = {}, delayed = {}, queue = {}, logs = {}, reads = 0, violations = 0 }
    state.bindings = {}
    local scriptDirectory = root .. "/mods/" .. modFolders[name] .. "/ue4ss/" .. name .. "/Scripts"
    local moduleCache = {}

    local function objectRead()
        state.reads = state.reads + 1
        if not state.onGameThread then state.violations = state.violations + 1 end
    end
    local function forbidden()
        error("Async scheduling is forbidden in these mods")
    end

    local function loadModule(moduleName)
        if moduleName == "UEHelpers" then
            return {
                GetPlayerController = function()
                    objectRead()
                    return state.controller
                end,
            }
        end
        if moduleCache[moduleName] then return moduleCache[moduleName] end

        local modulePath = scriptDirectory .. "/" .. moduleName .. ".lua"
        local moduleFile = assert(nativeOpen(modulePath, "rb"))
        local moduleSource = moduleFile:read("*a")
        moduleFile:close()
        moduleCache[moduleName] = assert(load(moduleSource, "@" .. modulePath, "t", state.env))()
        return moduleCache[moduleName]
    end

    state.env = setmetatable({
        print = function(message) state.logs[#state.logs + 1] = message end,
        require = loadModule,
        RegisterHook = function() end,
        RegisterKeyBind = function(key, callbackOrModifiers, modifierCallback)
            local callback = modifierCallback or callbackOrModifiers
            if key then state.bindings[modifierCallback and (callbackOrModifiers[1] .. "+" .. key) or key] = callback end
            if key == "LEFT_MOUSE_BUTTON" then state.click = callback end
        end,
        Key = {
            DOWN_ARROW = "DOWN_ARROW",
            E = "E",
            F6 = "F6",
            F7 = "F7",
            LEFT_ARROW = "LEFT_ARROW",
            LEFT_MOUSE_BUTTON = "LEFT_MOUSE_BUTTON",
            OEM_FOUR = "OEM_FOUR",
            OEM_SIX = "OEM_SIX",
            PAGE_DOWN = "PAGE_DOWN",
            PAGE_UP = "PAGE_UP",
            RIGHT_ARROW = "RIGHT_ARROW",
            UP_ARROW = "UP_ARROW",
        },
        ModifierKey = { CONTROL = "CONTROL", SHIFT = "SHIFT" },
        LoopAsync = forbidden,
        ExecuteWithDelay = forbidden,
        ExecuteAsync = forbidden,
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
        FindAllOf = function()
            objectRead()
            return {}
        end,
        FindFirstOf = function()
            objectRead()
            return nil
        end,
        StaticFindObject = function()
            objectRead()
            return nil
        end,
        io = {
            open = function(_, mode)
                if mode == "rb" then return nil, "not found", 2 end
                if name == "ZoneAtlas" and mode == "r" then return nil, "not found", 2 end
                error("Unexpected flag write")
            end,
        },
    }, { __index = _G })

    if configure then configure(state) end

    local path = scriptDirectory .. "/main.lua"
    local file = assert(nativeOpen(path, "rb"))
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
        for _, callback in ipairs(ready) do
            self:run(callback)
        end
    end
    function state:check()
        assert(self.violations == 0, "UObject read outside game thread")
        for _, message in ipairs(self.logs) do
            assert(not message:find("ERR"), message)
        end
    end
    return state
end

local zoneAtlas = loadMod("ZoneAtlas", "")
assert(#zoneAtlas.timers == 1)
assert(zoneAtlas:run(zoneAtlas.timers[1].callback) == false)
zoneAtlas:check()
print("PASS: ZoneAtlas loads mod-local modules and polls safely")

local originalLoadfile = zoneAtlas.env.loadfile
zoneAtlas.env.loadfile = function(path)
    if path:find("config.lua", 1, true) then
        return function() return { Key = 42, ToastSeconds = "invalid" } end
    end
    if path:find("atlas_manifest.lua", 1, true) then
        return function()
            return {
                { name = "Test map", texture = "/Game/Test.Test" },
                { name = false, texture = "/Game/Invalid.Invalid" },
            }
        end
    end
    return originalLoadfile(path)
end
local testCatalog = zoneAtlas.env.require("catalog").load("test/ZoneAtlas")
zoneAtlas.env.loadfile = originalLoadfile
assert(testCatalog.config.Key == "F6" and testCatalog.config.ToastSeconds == 2.5)
assert(#testCatalog.entries == 2 and testCatalog.ownedPaths["/Game/Test.Test"])
local invalidKeyLogged = false
local invalidManifestLogged = false
for _, message in ipairs(zoneAtlas.logs) do
    invalidKeyLogged = invalidKeyLogged or message:find("invalid config value for Key", 1, true) ~= nil
    invalidManifestLogged = invalidManifestLogged or message:find("invalid atlas manifest entry", 1, true) ~= nil
end
assert(invalidKeyLogged and invalidManifestLogged)
print("PASS: ZoneAtlas validates config types and skips malformed manifest entries")

local function atlasFixture(config, configure)
    return loadMod("ZoneAtlas", "", function(state)
        local function object(path)
            return {
                IsValid = function(self)
                    if not state.onGameThread then state.violations = state.violations + 1 end
                    assert(state.onGameThread, "ZoneAtlas UObject access outside game thread")
                    return not self.destroyed
                end,
                GetFullName = function() return "Object " .. path end,
            }
        end

        state.assets = {}
        for _, name in ipairs({ "Default", "Satellite", "Topographic", "Mismatch" }) do
            local path = "/Game/" .. name .. "." .. name
            state.assets[path] = object(path)
            state.assets[path].VirtualTextureStreaming = name == "Mismatch"
        end

        local material = object("MapMaterial")
        material.GetClass = function()
            return { GetFName = function()
                return { ToString = function() return "MaterialInstanceDynamic" end }
            end }
        end
        material.texture = state.assets["/Game/Default.Default"]
        material.K2_GetTextureParameterValue = function(self) return self.texture end
        material.SetTextureParameterValue = function(self, _, texture)
            self.texture = texture
            state.swaps = state.swaps + 1
        end
        state.material, state.swaps, state.time = material, 0, 0
        state.scene = object("WorldMapScene")
        state.scene.Map = object("MapMesh")
        state.scene.Map.GetMaterial = function() return material end
        state.scene.SceneCaptureComponent = { bCaptureEveryFrame = true }
        state.settings = {}
        state.manager = object("MCMManager")
        state.manager.AllSettings = { ForEach = function(_, callback)
            for name, enabled in pairs(state.settings) do
                callback(1, { get = function()
                    return {
                        ModID_19_16F2EB904B3610C78A68FE94C1064C9B = {
                            ToString = function() return "ZoneAtlas" end,
                        },
                        SettingID_20_5CDB958A4AF1113D73FA76BF15153E78 = {
                            ToString = function() return name end,
                        },
                        BoolValue_18_561E7B474E51CDC6C657A89251AA5995 = enabled,
                    }
                end })
            end
        end }
        state.manager.GetClass = function() return object("MCMManagerClass") end
        state.manager.AddUniqueModID = function() end
        state.manager.RegisterModSetting = function(_, _, name)
            state.settings[name] = true
        end
        state.manager.RegisterDefaultModSetting = function() end
        state.env.FindFirstOf = function() return state.scene end
        state.env.FindAllOf = function(class)
            return class == "BP_MCM_Manager_C" and { state.manager } or {}
        end
        state.env.StaticFindObject = function(path)
            if path == "/ModConfigurationMenu/BP_MCM_Manager.BP_MCM_Manager_C" then
                return state.manager
            end
            return state.assets[path]
        end
        state.env.os = { clock = function() return state.time end }
        state.env.FName = function(name) return name end
        state.env.loadfile = function(path)
            return function()
                if path:find("config.lua", 1, true) then
                    return config or { ShowHint = false, ToastSeconds = 0, UseMCM = false }
                end
                return {
                    { name = "Satellite", texture = "/Game/Satellite.Satellite" },
                    { name = "Topographic", texture = "/Game/Topographic.Topographic" },
                    { name = "Mismatch", texture = "/Game/Mismatch.Mismatch" },
                }
            end
        end
        state.env.io.open = function(_, mode)
            if mode == "r" then return nil end
            return {
                write = function(self, value)
                    state.savedName = value
                    return self
                end,
                close = function() return true end,
            }
        end

        function state:poll()
            self.time = self.time + 1
            self:run(self.timers[1].callback)
        end

        if configure then configure(state, object) end
    end)
end

local atlas = atlasFixture()
atlas:poll()
atlas.bindings.F6()
assert(atlas.swaps == 0, "A key callback accessed Unreal instead of queueing an intent")
atlas:poll()
assert(atlas.swaps == 0, "The Shift grace tick was lost")
atlas:poll()
assert(atlas.savedName == "Satellite" and atlas.swaps == 1)
local collectedTexture = atlas.assets["/Game/Satellite.Satellite"]
collectedTexture.destroyed = true
local reloadedTexture = {
    IsValid = collectedTexture.IsValid,
    GetFullName = collectedTexture.GetFullName,
    VirtualTextureStreaming = false,
}
atlas.assets["/Game/Satellite.Satellite"] = reloadedTexture
atlas:poll()
assert(atlas.material.texture == reloadedTexture, "A collected texture was not reloaded")
atlas.bindings.F6()
atlas.bindings["SHIFT+F6"]()
atlas:poll()
atlas:poll()
assert(atlas.savedName == "Game default", "Shift and plain binds advanced twice")
atlas.bindings["SHIFT+F6"]()
atlas:poll()
atlas:poll()
assert(atlas.savedName == "Topographic", "A mismatched virtual texture entered the cycle")
atlas.scene.destroyed = true
atlas.env.FindFirstOf = function() return nil end
atlas:poll()
atlas:check()
print("PASS: ZoneAtlas queues input, persists selection, skips unsafe textures, reloads collected assets, and survives scene loss")

local atlasMCM = atlasFixture({ ShowHint = false, ToastSeconds = 0 })
atlasMCM:poll()
atlasMCM.bindings.F6()
atlasMCM:poll()
atlasMCM:poll()
assert(atlasMCM.savedName == "Satellite")
atlasMCM.settings.Satellite = false
atlasMCM.settings.Topographic = true
atlasMCM.settings.Mismatch = false
atlasMCM.settings["Game default"] = false
for _ = 1, 5 do atlasMCM:poll() end
assert(atlasMCM.savedName == "Topographic", "MCM did not move away from a disabled map")
for name in pairs(atlasMCM.settings) do atlasMCM.settings[name] = false end
atlasMCM:poll()
atlasMCM.bindings.F6()
atlasMCM:poll()
atlasMCM:poll()
assert(atlasMCM.savedName == "Game default", "An empty MCM selection did not restore the full cycle")
atlasMCM:check()
print("PASS: ZoneAtlas honors MCM filtering and the empty-selection fallback")

local atlasUI = atlasFixture({ ShowHint = true, ToastSeconds = 2, UseMCM = false }, function(state, object)
    local capClass = object("KeyCapClass")
    local function widget()
        local result = object("Widget")
        result.ColorAndOpacity = {
            R = 1, G = 1, B = 1, A = 1,
            SpecifiedColor = { R = 1, G = 1, B = 1, A = 1 }, ColorUseRule = 0,
        }
        result.Font, result.TextSettings = "PDAFont", {}
        result.CommonTextObj = result
        result.GetVisibility = function(self) return self.visibility or 0 end
        result.SetVisibility = function(self, visibility) self.visibility = visibility end
        result.GetText = function(self) return { ToString = function() return self.text or "" end } end
        result.SetText = function(self, text) self.text = text end
        result.IsHovered = function(self) return self.hovered == true end
        result.GetClass = function() return capClass end
        result.SetFont = function(self, font) self.Font = font end
        result.SetColorAndOpacity = function(self, color) self.ColorAndOpacity = color end
        result.SetTextTransformPolicy = function(self, policy) self.TextTransformPolicy = policy end
        result.SetJustification = function(self, value) self.justification = value end
        result.SetShadowOffset = function(self, value) self.shadowOffset = value end
        result.SetShadowColorAndOpacity = function(self, value) self.shadowColor = value end
        result.AddToViewport = function(self, layer) self.layer = layer end
        result.SetDesiredSizeInViewport = function(self, value) self.size = value end
        result.SetAnchorsInViewport = function(self, value) self.anchors = value end
        result.SetAlignmentInViewport = function(self, value) self.alignment = value end
        result.SetPositionInViewport = function(self, value, removeDPI)
            self.position, self.removeDPI = value, removeDPI
        end
        result.RemoveFromParent = function(self) self.removed = true end
        return result
    end
    local row = object("HintRow")
    row.AddChild = function(_, child)
        state.children[#state.children + 1] = child
        return {
            SetPadding = function(_, value) child.padding = value end,
            SetVerticalAlignment = function(_, value) child.vertical = value end,
            SetSize = function(_, value) child.slotSize = value end,
        }
    end
    local source, sourceCap, sourceView = widget(), widget(), object("KeyboardView")
    sourceCap.HintChar = widget()
    sourceCap.HintChar.text = "P"
    sourceView.HintIconImage = sourceCap
    source.GetParent = function() return row end
    source.PlatformSwitcher = object("Switcher")
    source.PlatformSwitcher.GetActiveWidget = function() return sourceView end
    source.RightText = widget()
    source.RightText.text = "Existing prompt"
    source.Slot = { Padding = { Left = 4, Top = 2, Right = 4, Bottom = 2 } }
    state.page = object("MapPage")
    state.page.MoveToPlayerPositionHint = source
    state.children, state.created = {}, {}
    state.controller = object("PlayerController")
    state.env.FText = function(text) return text end
    state.env.NotifyOnNewObject = function(_, callback) state.notify = callback end
    local library = object("WidgetLibrary")
    library.Create = function(_, _, class)
        local created = widget()
        if class == capClass then created.HintChar = widget() end
        state.created[#state.created + 1] = created
        return created
    end
    local layout = object("LayoutLibrary")
    layout.GetViewportSize = function() return { X = 1920, Y = 1080 } end
    layout.GetViewportScale = function() return 2 end
    local findObject = state.env.StaticFindObject
    state.env.StaticFindObject = function(path)
        if path == "/Script/UMG.Default__WidgetBlueprintLibrary" then return library end
        if path == "/Script/UMG.Default__WidgetLayoutLibrary" then return layout end
        if path == "/Game/GameLite/FPS_Game/UIRemaster/CommonWidgets/W_Text.W_Text_C" then
            return object("TextClass")
        end
        return findObject(path)
    end
    state.setKeyboard = function(enabled) sourceView.HintIconImage = enabled and sourceCap or nil end
end)
atlasUI.notify(atlasUI.page)
atlasUI:poll()
atlasUI:poll()
local hintCap, hintLabel = atlasUI.children[1], atlasUI.children[2]
assert(hintCap.HintChar.text == "F6" and hintLabel.text == "Map style")
assert(hintLabel.Font == "PDAFont" and hintCap.padding.Left == 4 and hintLabel.vertical == 2)
atlasUI.setKeyboard(false)
atlasUI:poll()
assert(hintCap.visibility == 1 and hintLabel.visibility == 1, "Gamepad view did not collapse the keyboard hint")
atlasUI.setKeyboard(true)
atlasUI:poll()
assert(hintCap.visibility == 0 and hintLabel.visibility == 0)
hintCap.hovered = true
atlasUI.click()
atlasUI:poll()
assert(atlasUI.savedName == "Satellite", "Clicking the hint did not cycle the map")
local toast = atlasUI.created[#atlasUI.created]
assert(toast.text == "Satellite  (2/4)" and toast.visibility == 4 and toast.layer == 1000)
assert(toast.size.X == 640 and toast.position.X == 160 and toast.position.Y == 32.4)
assert(toast.removeDPI == false and toast.anchors.Minimum.X == 0)
atlasUI:poll()
atlasUI:poll()
assert(toast.removed, "Toast did not expire")
hintCap.destroyed = true
atlasUI:poll()
assert(atlasUI.children[3] ~= hintCap, "A stale key-cap widget was not rebuilt")
atlasUI.scene.destroyed = true
atlasUI.env.FindFirstOf = function() return nil end
atlasUI:poll()
atlasUI:check()
print("PASS: ZoneAtlas preserves native hints, keyboard/gamepad switching, clicks, DPI-aware toasts, expiry, and widget recovery")

local molotovExports = [[
local CraftMenu = require("craft_menu")
local Crafting = require("crafting")
local Hands = require("hands")
local HoldBurn = require("hold_burn")
local RagFire = require("rag_fire")
return { douse = RagFire.douse, restore = Hands.restore, fp = Hands.fp, mp = Hands.mp,
    injectCraft = CraftMenu.injectEntry, craftSelection = CraftMenu.craftSelection, menuCraft = CraftMenu.state,
    setCraftFire = function(callback) Crafting.craft = callback end,
    physics = RagFire.kickPhysics, fire = RagFire.light, currentMesh = Hands.currentRagMesh,
    disableHoldBurn = function() HoldBurn.isEnabled = false end }
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
print("PASS: finite native timers use explicit handle cancellation")

for _, cleanup in ipairs({ "douse", "restore" }) do
    for _, alreadyQueued in ipairs({ false, true }) do
        local state = loadMod("MolotovFire", molotovExports)
        local api = state.exports
        local touches = 0
        local anim = {
            IsValid = function()
                touches = touches + 1
                return true
            end,
        }
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
        .. iconName
        .. "."
        .. iconName
end
material.TextureParameterValues = {
    ForEach = function(_, callback)
        callback(1, {
            get = function()
                return {
                    ParameterInfo = { Name = { ToString = function() return "Icon" end } },
                    ParameterValue = texture,
                }
            end,
        })
    end,
}
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
    return {
        Create = function()
            local row = craftObject(110)
            row.Label = { SetText = function() end }
            row.IsHovered = function() return true end
            row.OnButtonUnHovered, row.OnButtonHovered = function() end, function() end
            row.RemoveFromParent = function() removedRows = removedRows + 1 end
            return row
        end,
    }
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
vodka = 0
inject()
vodka = 1
bandages = 0
inject()
bandages = 1
assert(rows == 2, "Missing ingredients must suppress the row")
inject()
vodka = 0
click()
vodka = 1
assert(crafts == 2, "Click must recheck ingredient counts")
inject()
iconName = "T_cns_pills_03"
click()
assert(crafts == 2 and not craft.exports.menuCraft.entry, "Stale selection crafted")
iconName = "T_cns_bandage_01"
inject()
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

local zone = loadMod(
    "ZoneXM",
    [[
return {
    bannerLine = Banner.truncateLine,
    bannerText = function(event)
        local firstLine, secondLine = Banner.parts(event)
        return firstLine .. secondLine
    end,
    pollBanner = Banner.tick,
    readNotification = Bridge.readNotification,
    readTrack = Bridge.readTrack,
}
]],
    function(state)
        state.env.os = setmetatable({
            getenv = function(name)
                assert(name == "USERPROFILE", "ZoneXM must not use a virtualized AppData bridge")
                return "C:\\ZoneXM Test User"
            end,
            remove = function(path)
                assert(path == "C:\\ZoneXM Test User\\ZoneXM\\alert.flag")
                return true
            end,
        }, { __index = os })
        local originalOpen = state.env.io.open
        state.env.io.open = function(path, mode)
            assert(path:find("C:\\ZoneXM Test User\\ZoneXM\\", 1, true) == 1)
            return originalOpen(path, mode)
        end
    end
)
assert(#zone.timers == 2 and zone.reads == 0)
zone.controller = {
    IsValid = function() return true end,
    IsInStaticDialog = function() return false end,
    Pawn = {
        IsValid = function() return true end,
        K2_GetActorLocation = function() return { X = 0, Y = 0, Z = 0 } end,
    },
}
for _, timer in ipairs(zone.timers) do
    assert(zone:run(timer.callback) == false)
end
assert(zone.reads > 0)
zone:check()
print("PASS: ZoneXM polls Unreal objects on native game-thread timers")

local snapshot, notificationSnapshot, styleSnapshot, paused, created, removed = nil, nil, nil, false, {}, 0
zone.controller.GetAddress = function() return 123 end
zone.env.FText = function(text) return text end
zone.env.FName = function(text) return text end
local function openSnapshot(path, mode)
    assert(path:find("C:\\ZoneXM Test User\\ZoneXM\\", 1, true) == 1, "ZoneXM used a different shared folder")
    if path:match("subtitle%-style%.txt$") then
        if mode == "wb" then
            local buffer = {}
            return {
                write = function(self, text)
                    buffer[#buffer + 1] = text
                    return self
                end,
                close = function() styleSnapshot = table.concat(buffer); return true end,
            }
        end
        assert(mode == "rb")
        if not styleSnapshot then return nil, "not found", 2 end
        return { read = function(_, count) return styleSnapshot:sub(1, count) end, close = function() return true end }
    end
    assert(mode == "rb")
    local data = snapshot
    if path:match("notification%.txt$") then data = notificationSnapshot end
    if not data then return nil, "not found", 2 end
    return { read = function(_, count) return data:sub(1, count) end, close = function() return true end }
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
    IsValid = valid,
    Font = {
        Size = 20,
        FontObject = subtitleFont,
        FontMaterial = speakerMaterial,
        TypefaceFontName = "Bold",
        LetterSpacing = 2,
        OutlineSettings = {
            OutlineSize = 1,
            OutlineMaterial = speakerOutline,
            bApplyOutlineToDropShadows = true,
            OutlineColor = { R = 0, G = 0, B = 0, A = 1 },
        },
    },
    ColorAndOpacity = { SpecifiedColor = { R = 1, G = 0.55, B = 0, A = 1 } },
    ShadowOffset = { X = 1, Y = 1 },
    ShadowColorAndOpacity = { R = 0, G = 0, B = 0, A = 1 },
}
local bodyStyle = {
    IsValid = valid,
    Font = {
        Size = 20,
        FontObject = subtitleFont,
        FontMaterial = bodyMaterial,
        TypefaceFontName = "Bold",
        LetterSpacing = 2,
        OutlineSettings = {
            OutlineSize = 1,
            OutlineMaterial = bodyOutline,
            bApplyOutlineToDropShadows = true,
            OutlineColor = { R = 0, G = 0, B = 0, A = 1 },
        },
    },
    ColorAndOpacity = { SpecifiedColor = { R = 1, G = 1, B = 1, A = 1 }, ColorUseRule = 0 },
    ShadowOffset = { X = 1, Y = 1 },
    ShadowColorAndOpacity = { R = 0, G = 0, B = 0, A = 1 },
}
local subtitleView = {
    IsValid = valid,
    SpeakerDialogText = { IsValid = valid, CommonTextObj = speakerStyle },
    TextDialog = { IsValid = valid, CommonTextObj = bodyStyle },
}
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
        return {
            IsValid = valid,
            GetViewportSize = function() return viewport end,
            GetViewportScale = function() return viewportScale end,
        }
    end
    if path:find("WidgetBlueprintLibrary") then
        return {
            IsValid = valid,
            Create = function(_, pc)
                assert(pc == zone.controller)
                local isBody = creatingBody
                creatingBody = not creatingBody
                local titleWidget = isBody and created[#created] or nil
                local widget = {
                    IsValid = valid,
                    AddToViewport = noop,
                    ForceLayoutPrepass = noop,
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
                        IsValid = valid,
                        SetAutoWrapText = noop,
                        Font = { Size = 18 },
                        SetFont = function(self, font) self.Font = font end,
                        SetJustification = function(self, value) self.justification = value end,
                        SetColorAndOpacity = function(self, value) self.ColorAndOpacity = value end,
                        SetShadowOffset = function(self, value) self.ShadowOffset = value end,
                        SetShadowColorAndOpacity = function(self, value) self.ShadowColorAndOpacity = value end,
                        GetDesiredSize = function(self) return { X = #(self.value or "") * 10, Y = 24 } end,
                        GetText = function(self)
                            return { ToString = function() return self.value or "" end }
                        end,
                    },
                }
                if isBody then
                    titleWidget.body = widget
                else
                    created[#created + 1] = widget
                end
                return widget
            end,
        }
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
assert(
    layout.anchors.Minimum.X == 0
        and layout.anchors.Minimum.Y == 0
        and layout.anchors.Maximum.X == 0
        and layout.anchors.Maximum.Y == 0
)
assert(layout.alignment.X == 0 and layout.alignment.Y == 0 and layout.size.X == 60 and layout.size.Y == 100)
assert(layout.partText == "Artist" and layout.body.partText == " - First song")
assert(
    layout.CommonTextObj.Font == speakerStyle.Font
        and layout.CommonTextObj.ColorAndOpacity == speakerStyle.ColorAndOpacity
)
assert(
    layout.body.CommonTextObj.Font == bodyStyle.Font
        and layout.body.CommonTextObj.ColorAndOpacity == bodyStyle.ColorAndOpacity
)
assert(
    layout.CommonTextObj.Font.FontMaterial == speakerMaterial
        and layout.body.CommonTextObj.Font.FontMaterial == bodyMaterial
        and layout.CommonTextObj.Font.OutlineSettings.OutlineMaterial == speakerOutline
        and layout.body.CommonTextObj.Font.OutlineSettings.OutlineMaterial == bodyOutline
        and layout.body.CommonTextObj.Font.OutlineSettings.bApplyOutlineToDropShadows
        and layout.CommonTextObj.Font.TypefaceFontName == "Bold"
        and layout.CommonTextObj.Font.LetterSpacing == 2,
    "Subtitle font materials/outline/spacing were lost"
)
assert(
    layout.CommonTextObj.ShadowOffset == speakerStyle.ShadowOffset
        and layout.body.CommonTextObj.ShadowColorAndOpacity == bodyStyle.ShadowColorAndOpacity
)
assert(speakerStyle.Font.Size == 20 and bodyStyle.Font.Size == 20, "Live subtitle style was modified")
assert(layout.CommonTextObj.justification == 0 and layout.body.CommonTextObj.justification == 0)
for _, dimensions in ipairs({ { 1920, 1080, 1 }, { 3840, 2160, 2 }, { 800, 600, 1 }, { 400, 300, 2 } }) do
    viewport, viewportScale = { X = dimensions[1], Y = dimensions[2] }, dimensions[3]
    poll(100)
    local w, h = viewport.X / viewportScale, viewport.Y / viewportScale
    assert(math.abs(layout.body.position.X + layout.body.size.X - (w - math.min(64, w / 10))) < 0.001)
    assert(layout.position.X + layout.size.X == layout.body.position.X, "Subtitle segments overlap or gap")
    assert(math.abs(layout.position.Y + layout.size.Y - (h - math.min(80, h / 10))) < 0.001)
    assert(
        layout.position.X >= 0
            and layout.position.Y >= 0
            and layout.position.X + layout.size.X <= w
            and layout.position.Y + layout.size.Y <= h,
        "Banner extends outside DPI-scaled viewport"
    )
end
assert(#created == 1, "Resize recreated or repeated the banner")
viewport, viewportScale = { X = 3440, Y = 1440 }, 4 / 3
track(101, "First song", "Artist")
poll(101)
assert(#created == 1, "Heartbeat repeated a banner")
poll(106)
assert(removed == 1, "Banner did not expire after six seconds")
assert(layout.removed and layout.body.removed, "Subtitle segments not both removed")
assert(zone.logs[#zone.logs]:find("banner dismissed: six%-second expiry, age=6s"), "Banner lifetime diagnostic missing")
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
    "",
    "ZoneXM/2\n100\nsource\ntitle\nartist\n",
    "ZoneXM/1\n100\nsource\ntitle\n",
    string.rep("a", 4097),
    "ZoneXM/1\n100\nsource\ntitle\0\nartist\n",
    "ZoneXM/1\n100\nsource\n\255\nartist\n",
}) do
    snapshot = bad
    assert(not pcall(zone.exports.readTrack, 100), "Malformed snapshot accepted")
end
snapshot = "bad snapshot"
poll(121)
local errorLogged = false
for _, message in ipairs(zone.logs) do
    if message:find("banner ERROR") then errorLogged = true end
end
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
    notificationSnapshot = string.format(
        "ZoneXM/notification/1\n%d\n%d\nApp.Id\n%s\n%s\n%s\n%s\n",
        now,
        received,
        id,
        app or "Pandora",
        title or "Notification",
        body or "Body"
    )
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
assert(
    #created == 9 and created[9].text == "Latest - Newest only",
    "Notification was suppressed during danger/dialogue"
)
local receiptLogged = false
for i = beforeReceipt + 1, #zone.logs do
    assert(
        not zone.logs[i]:find("Latest") and not zone.logs[i]:find("Newest"),
        "Diagnostic leaked notification contents"
    )
    if zone.logs[i]:find("notification event received by game %(age=0s%)") then receiptLogged = true end
end
assert(receiptLogged, "Event receipt diagnostic missing")
notification(144, 144, "event5", "Paused", "Waiting")
paused = true
poll(144)
assert(
    #created == 9 and zone.logs[#zone.logs]:find("notification waiting: game paused or no player"),
    "Paused notification wait was not diagnosed"
)
local waitLogs = #zone.logs
poll(145)
assert(#zone.logs == waitLogs, "Waiting diagnostic repeated every poll")
notification(175, 144, "event5", "Paused", "Waiting")
poll(175)
assert(
    zone.logs[#zone.logs]:find("notification not displayed: event age 31s is outside the 30%-second window")
        and not zone.logs[#zone.logs]:find("Paused"),
    "Expired notification was not diagnosed"
)
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
assert(
    #created == 11 and removed == removedBeforeFallback + 1,
    "Returning to an already-shown media track left the notification widget visible"
)
assert(zone.exports.bannerText({ title = "Title only", artist = "", notification = true }) == "Title only")
assert(zone.exports.bannerText({ title = "Title", artist = "Body", notification = true }) == "Title - Body")
notificationSnapshot =
    "ZoneXM/notification/1\n193\n193\nPandoraMediaInc.29680B314EFC2_n619g4d5j0fnw!App\npandora-test\nPandora\nRock With Me\nRebelution\n"
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
assert(
    zone.logs[#zone.logs - 1]:find("invalid banner viewport") or zone.logs[#zone.logs]:find("invalid banner viewport"),
    "Invalid viewport was not surfaced"
)
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
assert(
    created[#created].CommonTextObj.Font == speakerStyle.Font
        and created[#created].CommonTextObj.ShadowOffset == speakerStyle.ShadowOffset
        and created[#created].body.CommonTextObj.Font == bodyStyle.Font,
    "Retained style lost original font/material/shadow data"
)
subtitleView = savedSubtitles
local largeFont = asset("Font", "/Game/UI/Fonts/SubtitleLarge.SubtitleLarge")
for _, style in ipairs({ speakerStyle, bodyStyle }) do
    local font = {}
    for key, value in pairs(style.Font) do
        font[key] = value
    end
    font.Size, font.FontObject = 26, largeFont
    style.Font = font
end
track(221, "New subtitle setting", "Band")
poll(221)
local styled = created[#created]
assert(
    styled.CommonTextObj.Font.Size == 26 and styled.body.CommonTextObj.Font.Size == 26,
    "New banner did not pick up current subtitle font size"
)
assert(
    styled.CommonTextObj.ColorAndOpacity == speakerStyle.ColorAndOpacity
        and styled.body.CommonTextObj.ColorAndOpacity == bodyStyle.ColorAndOpacity
)
poll(227)
assert(styled.removed and styled.body.removed)
assert(
    styleSnapshot
        and styleSnapshot:find("/Game/UI/Fonts/SubtitleLarge.SubtitleLarge|", 1, true)
        and styleSnapshot:find("|26|", 1, true),
    "Changed subtitle style was not persisted"
)
for _, text in ipairs({ "New subtitle setting", "Band", "Missing style", "Latest", "Rebelution" }) do
    assert(not styleSnapshot:find(text, 1, true), "Saved style leaked banner text")
end
print(
    "PASS: subtitle font/size, separate speaker/body colors, read-only style copying, missing-style diagnostics and recovery"
)
subtitleView = { IsValid = function() return false end }
savedSubtitles.GetFullName = function() return "SubtitleView live" end
subtitleCandidates = { savedSubtitles }
track(230, "Second live subtitle view")
poll(230)
assert(created[#created].text == "Second live subtitle view", "Invalid first subtitle view hid a live candidate")
subtitleCandidates = {}
subtitleView = nil
for _, holder in ipairs(styleHolders) do
    holder.IsValid = function() return false end
end
local function assertSavedStyle(widget, message)
    local font, bodyFont = widget.CommonTextObj.Font, widget.body.CommonTextObj.Font
    assert(
        font ~= speakerStyle.Font
            and font.FontObject == largeFont
            and font.Size == 26
            and font.FontMaterial == speakerMaterial
            and font.OutlineSettings.OutlineMaterial == speakerOutline
            and font.OutlineSettings.bApplyOutlineToDropShadows
            and font.TypefaceFontName == "Bold"
            and font.LetterSpacing == 2
            and bodyFont.FontMaterial == bodyMaterial,
        message
    )
    local color = widget.CommonTextObj.ColorAndOpacity.SpecifiedColor
    assert(
        color.R == 1
            and color.G == 0.55
            and color.B == 0
            and widget.body.CommonTextObj.ColorAndOpacity.SpecifiedColor.G == 1
            and widget.CommonTextObj.ShadowOffset.X == 1,
        message
    )
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
assert(
    created[#created].CommonTextObj.Font == speakerStyle.Font,
    "Live subtitles did not take priority over saved style"
)
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
print(
    "PASS: retained styles survive missing SubtitleView; invalid-first lookup, GC, and player transitions recover safely"
)
subtitleView = nil
zone.controller.GetAddress = function() return 989 end
local goodStyle = styleSnapshot
assets["/Game/UI/Materials/MI_Speaker.MI_Speaker"] = nil
track(266, "Optional material unloaded")
poll(266)
assert(
    created[#created].text == "Optional material unloaded"
        and created[#created].CommonTextObj.Font.FontObject == largeFont
        and created[#created].CommonTextObj.Font.FontMaterial == nil,
    "Missing optional material blocked saved style"
)
assets["/Game/UI/Materials/MI_Speaker.MI_Speaker"] = speakerMaterial
local function assertFallback(now, text, reason)
    track(now, text)
    poll(now)
    local widget = created[#created]
    assert(widget.text == text, "Fallback did not display the banner: " .. reason)
    assert(
        widget.CommonTextObj.Font.Size == 18
            and widget.CommonTextObj.ColorAndOpacity.SpecifiedColor.B == 0.1
            and widget.body.CommonTextObj.ColorAndOpacity.SpecifiedColor.B == 1,
        "Fallback colors wrong: " .. reason
    )
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
assert(
    created[#created].text == "Font loaded on demand" and created[#created].CommonTextObj.Font.FontObject == largeFont,
    "Unloaded saved font was not loaded"
)
zone.env.LoadAsset = nil
assets["/Game/UI/Fonts/SubtitleLarge.SubtitleLarge"] = largeFont
subtitleView = savedSubtitles
print(
    "PASS: saved subtitle style covers fresh loads; optional materials degrade; cold/corrupt/missing-font fall back visibly"
)
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
assert(
    created[#created].text == "Artist - First event after dialogue disappeared",
    "Banner could not use styles captured before the first notification"
)
assert(created[#created].CommonTextObj.Font == speakerStyle.Font, "Retained live style lost priority")
print("PASS: idle style capture survives dialogue ending and combat deferral without widget churn")

zone.env.io.open = function()
    return {
        close = function() return nil, "close failed" end,
        read = function() return "ZoneXM/1\n300\nPlayer\nTitle\nArtist\n" end,
    }
end
assert(not pcall(zone.exports.readTrack, 300), "Snapshot close failure was hidden")
zone.env.io.open = openSnapshot

local alertAttempts, alertRemovals, alertTime, isTalking = 0, 0, 300, true
local sensorState = loadMod("ZoneXM", "", function(state)
    state.env.os = setmetatable({
        getenv = function() return "C:\\ZoneXM Sensor Test" end,
        remove = function()
            alertRemovals = alertRemovals + 1
            return true
        end,
        time = function() return alertTime end,
    }, { __index = os })
    state.env.io.open = function(path, mode)
        if mode == "rb" then return nil, "not found", 2 end

        assert(path == "C:\\ZoneXM Sensor Test\\ZoneXM\\alert.flag" and mode == "w")
        alertAttempts = alertAttempts + 1

        if alertAttempts <= 2 then return nil, "directory missing", 2 end

        return {
            close = function()
                if alertAttempts == 3 then return nil, "close failed" end
                return true
            end,
            write = function(self, timestamp)
                assert(timestamp == tostring(alertTime))
                return self
            end,
        }
    end
end)
sensorState.controller = {
    GetAddress = function() return 1 end,
    IsInStaticDialog = function() return isTalking end,
    IsValid = valid,
    Pawn = { IsValid = valid },
}
local sensorPoll = sensorState.timers[2].callback

for _ = 1, 4 do
    sensorState:run(sensorPoll)
end

assert(alertAttempts == 4, "Failed alert writes/close were incorrectly counted as a heartbeat")
sensorState:run(sensorPoll)
assert(alertAttempts == 4, "Successful alert write did not respect heartbeat cadence")
alertTime = 303
sensorState:run(sensorPoll)
assert(alertAttempts == 5, "Alert heartbeat did not refresh after three seconds")
isTalking, alertTime = false, 306
sensorState:run(sensorPoll)
assert(alertRemovals == 1, "Alert was not cleared after the speech holdoff")
assert(sensorState.violations == 0, "Extracted sensors accessed Unreal objects outside the game thread")

local writeErrors = 0

for _, message in ipairs(sensorState.logs) do
    if message:find("alert flag write ERROR", 1, true) then writeErrors = writeErrors + 1 end
end

assert(writeErrors == 2, "Repeated write errors were not deduplicated or close failures were not reported")
sensorState.controller = nil
local sensorLogCount = #sensorState.logs
sensorState:run(sensorState.timers[1].callback)
assert(#sensorState.logs == sensorLogCount and sensorState.violations == 0, "Absent player was treated as a radar error")
print("PASS: module isolation, snapshot close errors, failed flag-write retries, heartbeat cadence and clearing")

local codexIcon = "/Game/GameLite/FPS_Game/UIRemaster/UITextures/Inventory/Artifacts/Art.Art"
local codexData = {
    fallbacks = {
        sid_lore_freedom = "English lore",
        sid_misc_Faction_Enemy_Name = "Enemy",
        sid_misc_answer_faction_Duty = "Duty",
        sid_misc_answer_faction_Freedom = "Freedom",
    },
    tabs = {
        {
            bulletsTitle = "Effects",
            entries = {},
            id = "artifacts",
            title = "Artifacts",
            tracksInventory = true,
        },
        {
            bulletsTitle = "Stance toward others",
            descriptionFirst = true,
            entries = {
                {
                    bullets = { "{sid_misc_answer_faction_Duty}: {sid_misc_Faction_Enemy_Name}", "Monolith: Enemy of everyone" },
                    -- sid_lore_gone has neither game text nor a fallback, so its paragraph drops out.
                    description = "{sid_lore_freedom}\n\n{sid_lore_gone}",
                    facts = { { "Starting standing", "{sid_misc_Faction_Enemy_Name}" } },
                    icon = codexIcon,
                    id = "Freedom",
                    name = "{sid_misc_answer_faction_Freedom}",
                    sids = {},
                },
            },
            id = "factions",
            maskIcons = true,
            title = "Factions",
            tracksInventory = false,
        },
    },
}

for index = 1, 8 do
    codexData.tabs[1].entries[index] = {
        bullets = { "Radiation +" .. index },
        description = "The quick brown fox jumps over the lazy dog near the old Zone checkpoint.",
        facts = { { "Anomaly", "Thermal" } },
        icon = index == 2 and "/Game/Missing.Missing" or codexIcon,
        id = "Art" .. index,
        -- Artifact 1 stands in for a mutant: a large render beside the text, its part in the header.
        detailIcon = index == 1 and codexIcon or nil,
        image = index == 1 and codexIcon or nil,
        name = "Artifact " .. index,
        sids = { "Art" .. index },
    }
end

codexData.tabs[1].entries[9] = { id = "broken" }

local function codexFixture(config, archiveState, options)
    options = options or {}

    return loadMod("ZoneCodex", "", function(state)
        local function object(name)
            return {
                IsHovered = function(self) return self.hovered == true end,
                IsValid = function(self)
                    if not state.onGameThread then state.violations = state.violations + 1 end
                    return not self.destroyed
                end,
                GetFullName = function() return name end,
                RemoveFromParent = function(self)
                    self.removed = true
                    local siblings = self.parent and self.parent.children or {}
                    for index = #siblings, 1, -1 do
                        if siblings[index] == self then table.remove(siblings, index) end
                    end
                end,
                SetVisibility = function(self, value) self.visibility = value end,
            }
        end

        local function widget()
            local result = object("W_Text_C")
            result.CommonTextObj = result
            result.TextSettings = {}
            result.AddToViewport = function(self, layer) self.layer = layer end
            result.SetAlignmentInViewport = function() end
            result.SetAnchorsInViewport = function() end
            result.SetAutoWrapText = function(self, value) self.autoWrap = value end
            result.SetClipping = function(self, value) self.clipping = value end
            result.SetColorAndOpacity = function() end
            result.SetDesiredSizeInViewport = function(self, value) self.size = value end
            result.SetJustification = function() end
            result.SetPositionInViewport = function(self, value) self.position = value end
            result.SetShadowColorAndOpacity = function() end
            result.SetShadowOffset = function() end
            result.SetText = function(self, text) self.text = text end
            return result
        end

        local function texture(width, height)
            local result = object("Texture2D")
            result.Blueprint_GetSizeX = function() return width end
            result.Blueprint_GetSizeY = function() return height end
            return result
        end

        -- Vanilla W_PDABookView_C: collapsed, disabled Archive button and an "In Progress" page.
        function state.makeBook(path)
            local book = object("W_PDABookView_C " .. path)
            book.IsInViewport = function() return state.pdaVisible end
            book.IsVisible = function() return state.pdaVisible end

            local button = object("W_PDANavPanelSlot_C BestiaryBtn")
            button.enabled, button.visibility = false, archiveState == "button" and 0 or 1
            button.GetIsEnabled = function(self) return self.enabled end
            button.GetVisibility = function(self) return self.visibility end
            button.SetIsEnabled = function(self, value) self.enabled = value end

            local root = object("Overlay_25")
            root.children = { object("TextBlock_45") }
            root.AddChildToOverlay = function(self, child)
                self.children[#self.children + 1] = child
                child.parent = self
                child.slot = {
                    SetHorizontalAlignment = function(slot, value) slot.horizontal = value end,
                    SetPadding = function(slot, value) slot.padding = value end,
                    SetVerticalAlignment = function(slot, value) slot.vertical = value end,
                }
                return child.slot
            end
            root.GetChildAt = function(self, index) return self.children[index + 1] end
            root.GetChildrenCount = function(self) return #self.children end

            if archiveState == "page" then root.children[2] = object("ForeignWidget") end

            local page = object("W_BestiaryPage_C")
            page.WidgetTree = { RootWidget = root }

            local switcher = object("Switcher")
            switcher.GetActiveWidgetIndex = function() return state.activePage end
            switcher.GetChildIndex = function(_, child) return child == page and 6 or -1 end

            book.BestiaryPage, book.Switcher = page, switcher
            book.NavigationPanel = { BestiaryBtn = button }
            book.button, book.placeholder, book.root = button, root.children[1], root
            return book
        end

        state.activePage, state.countReads, state.created, state.images, state.inventory = 0, 0, {}, {}, { Art2 = 3 }
        state.findCount, state.now, state.pdaVisible, state.sounds = 0, 100, false, {}
        state.culture = "uk"
        state.localized = { sid_lore_freedom = "<b>Freedom</b> fights for the Zone.", sid_misc_answer_faction_Freedom = "Svoboda" }
        state.book = state.makeBook("/Game/PDA")
        state.controller = object("PlayerController")
        state.controller.Pawn = object("Pawn")
        state.controller.Pawn.K2_GetActorLocation = function() return { X = 1, Y = 2, Z = 3 } end
        state.env.FName = function(value) return { ToString = function() return value end } end
        state.env.FText = function(text) return text end
        state.env.NotifyOnNewObject = function(class, callback)
            assert(class == "/Script/Stalker2.PDAView")
            state.notify = callback
        end
        state.env.os = { time = function() return state.now end }
        state.env.loadfile = function(path)
            if path:find("config.lua", 1, true) then return function() return config end end
            if path:find("codex_data.lua", 1, true) then return function() return codexData end end
            error("Unexpected loadfile " .. path)
        end

        local defaultBook = object("W_PDABookView_C Default__W_PDABookView_C")
        state.env.FindAllOf = function(class)
            if not state.onGameThread then state.violations = state.violations + 1 end
            if class == "W_PDABookView_C" then
                state.findCount = state.findCount + 1
                return { defaultBook, state.book }
            end
            return nil
        end

        local mediator = object("Default__CppMediator")
        mediator.GetItemsCountInInventory = function(_, pawn, sid)
            assert(pawn == state.controller.Pawn, "Counts were not read for the player pawn")
            state.countReads = state.countReads + 1
            if state.countFailure then return nil end
            return state.inventory[sid] or 0
        end
        local library = object("WidgetLibrary")
        library.Create = function()
            local created = widget()
            state.created[#state.created + 1] = created
            return created
        end
        local layout = object("LayoutLibrary")
        layout.GetViewportScale = function() return 2 end
        layout.GetViewportSize = function() return { X = 3840, Y = 2160 } end
        layout.GetMousePositionOnPlatform = function() return { X = 300, Y = 200 } end
        local textLibrary = object("Default__KismetTextLibrary")
        textLibrary.FindTextInLocalizationTable = function(_, namespace, key, outText, source)
            assert(state.onGameThread and namespace == "ST_S2BaseGameLocalization" and source == "")
            local text = state.localized[key]
            if not text then return false end
            outText.OutText = { ToString = function() return text end }
            return true
        end
        local internationalization = object("Default__KismetInternationalizationLibrary")
        internationalization.GetCurrentCulture = function() return state.culture end
        local imageClass = object("Image")
        local scrollBoxClass = object("ScrollBox")
        local sizeBoxClass = object("SizeBox")
        local spacerClass = object("Spacer")
        local textClass = object("W_Text_C")
        local akStatics = object("Default__AkGameplayStatics")
        akStatics.PostEventAtLocation = function(_, event, location, orientation, context)
            assert(state.onGameThread, "Sound posted outside the game thread")
            assert(location.Z == 3 and orientation.Yaw == 0 and context == state.controller.Pawn, "Sound was not posted at the player")
            state.sounds[#state.sounds + 1] = event:GetFullName():match("([^.]+)$")
            return 1
        end
        state.wheels = {}

        local function panel(name)
            local result = object(name)
            result.children = {}
            result.AddChild = function(self, child)
                self.children[#self.children + 1] = child
                child.parent = self
                child.slot = {
                    SetHorizontalAlignment = function(slot, value) slot.horizontal = value end,
                    SetVerticalAlignment = function(slot, value) slot.vertical = value end,
                }
                return child.slot
            end
            return result
        end

        if not options.noImages then
            state.env.StaticConstructObject = function(class, outer)
                assert(outer.RootWidget, "Widgets must be owned by the page's widget tree")
                if class == scrollBoxClass then
                    local function brush() return { DrawAs = 2, TintColor = { SpecifiedColor = { R = 1, G = 1, B = 1, A = 1 } } } end
                    local result = panel("ScrollBox")
                    result.offset = 0
                    result.GetScrollOffset = function(self) return self.offset end
                    result.GetScrollOffsetOfEnd = function() return 300 end
                    result.ScrollToStart = function(self) self.offset = 0 end
                    result.SetScrollBarVisibility = function(self, value) self.scrollBarVisibility = value end
                    result.SetScrollbarThickness = function(self, value) self.thickness = value end
                    result.SetScrollOffset = function(self, value) self.offset = value end
                    result.WidgetBarStyle = {
                        DraggedThumbImage = brush(),
                        HoveredThumbImage = brush(),
                        NormalThumbImage = brush(),
                        VerticalBackgroundImage = brush(),
                    }
                    result.WidgetStyle = { BottomShadowBrush = brush(), TopShadowBrush = brush() }
                    state.wheels[#state.wheels + 1] = result
                    return result
                elseif class == sizeBoxClass then
                    local result = panel("SizeBox")
                    result.SetHeightOverride = function(self, value) self.height = value end
                    result.SetMaxDesiredHeight = function(self, value) self.maxHeight = value end
                    result.SetWidthOverride = function(self, value) self.width = value end
                    return result
                elseif class == spacerClass then
                    local result = object("Spacer")
                    result.SetSize = function(self, value) self.size = value end
                    return result
                end
                assert(class == imageClass, "Unexpected widget class")
                local result = object("Image")
                result.SetBrushResourceObject = function(self, value) self.brush = value end
                result.SetColorAndOpacity = function(self, value) self.color = value end
                result.SetRenderScale = function(self, value) self.renderScale = value end
                -- The game's UImage has no SetBrushSize; the size lives in the Brush struct.
                result.Brush = { ImageSize = { X = 32, Y = 32 } }
                result.SetDesiredSizeOverride = function() end
                state.images[#state.images + 1] = result
                return result
            end
        end

        state.env.LoadAsset = function(path)
            assert(state.onGameThread, "LoadAsset outside the game thread")
            return path == codexIcon and texture(64, 32) or nil
        end
        state.env.StaticFindObject = function(path)
            if not state.onGameThread then state.violations = state.violations + 1 end
            if path == "/Script/Stalker2.Default__CppMediator" then return mediator end
            if path == "/Script/UMG.Default__WidgetBlueprintLibrary" then return library end
            if path == "/Script/UMG.Default__WidgetLayoutLibrary" then return layout end
            if path == "/Script/UMG.Image" then return imageClass end
            if path == "/Script/UMG.ScrollBox" then return scrollBoxClass end
            if path == "/Script/UMG.SizeBox" then return sizeBoxClass end
            if path == "/Script/UMG.Spacer" then return spacerClass end
            if path == "/Game/GameLite/FPS_Game/UIRemaster/CommonWidgets/W_Text.W_Text_C" then return textClass end
            if path == "/Script/AkAudio.Default__AkGameplayStatics" then return akStatics end
            if path == "/Script/Engine.Default__KismetTextLibrary" then return textLibrary end
            if path == "/Script/Engine.Default__KismetInternationalizationLibrary" then return internationalization end
            if path:find("^/Game/_STALKER2/Audio/WwiseAudio/Events/UI/PDA/") then return object(path) end
            if path:find("^/Game/GameLite/FPS_Game/UIRemaster/UITextures/PDA/") then return texture(32, 32) end
            return nil
        end
    end)
end

local function codexLogCount(state, text)
    local count = 0

    for _, message in ipairs(state.logs) do
        if message:find(text, 1, true) then count = count + 1 end
    end

    return count
end

local function codexLogged(state, text)
    return codexLogCount(state, text) > 0
end

-- Fallback widgets are created as header, detail, one per tab, then one per visible row.
local function codexWidgets(state, first)
    first = first or 1
    local created = state.created
    return {
        detail = created[first + 1],
        header = created[first],
        rows = { table.unpack(created, first + 4, first + 9) },
        tabs = { created[first + 2], created[first + 3] },
    }
end

-- Archive texts: selected + idle label per tab, name + subtitle per row, title, subtitle, body,
-- status, controls.
-- Archive images: 7 frame pieces, left cap + middle + right cap per tab, hover + selected + icon
-- per row, icon box, icon, divider, picture.
local function codexPageWidgets(state, firstText, firstImage)
    local texts, images = state.created, state.images
    local page = { rows = {}, tabs = {} }

    for index = 1, 2 do
        local label, cap = firstText + 2 * (index - 1), firstImage + 4 + 3 * index
        page.tabs[index] = {
            background = images[cap + 1],
            idleLabel = texts[label + 1],
            label = texts[label],
            leftCap = images[cap],
            rightCap = images[cap + 2],
        }
    end

    for row = 1, 6 do
        local text, image = firstText + 2 + 2 * row, firstImage + 10 + 3 * row
        page.rows[row] = { hover = images[image], icon = images[image + 2], name = texts[text], selected = images[image + 1], subtitle = texts[text + 1] }
    end

    page.title, page.subtitle, page.body = texts[firstText + 16], texts[firstText + 17], texts[firstText + 18]
    page.status, page.controls = texts[firstText + 19], texts[firstText + 20]
    page.iconBox, page.icon, page.divider = images[firstImage + 31], images[firstImage + 32], images[firstImage + 33]
    page.picture = images[firstImage + 34]
    return page
end

-- Selected tabs use W_PDAUpgradesButton's light ButtonCollorDisable, in linear colour.
local function isSelectedTab(tab)
    local tinted = tab.background.color.R > 0.5 and tab.leftCap.color.R > 0.5 and tab.rightCap.color.R > 0.5
    return tinted and tab.label.visibility == 3 and tab.idleLabel.visibility == 1
end

local function isIdleTab(tab)
    local tinted = tab.background.color.R < 0.05 and tab.leftCap.color.R < 0.05 and tab.rightCap.color.R < 0.05
    return tinted and tab.label.visibility == 1 and tab.idleLabel.visibility == 3
end

local function takeSounds(state)
    local sounds = table.concat(state.sounds, ",")
    state.sounds = {}
    return sounds
end

local codex = codexFixture({ ArchiveDetailColumns = 24, ArchiveDetailLines = 6, ArchiveRows = 6, DetailColumns = 24, VisibleRows = 6 })
local function codexPoll() codex:run(codex.timers[1].callback) end
local function codexPress(key, times)
    for _ = 1, times or 1 do codex.bindings[key]() end
end

assert(#codex.timers == 1 and codex.timers[1].delay == 100)
assert(codexLogged(codex, "2 tabs, 9 entries; PDA Archive tab, or Ctrl+E as a fallback"))
assert(codexLogged(codex, "invalid codex entry Artifacts[9]"))
assert(codex.bindings["CONTROL+E"] and codex.bindings.LEFT_MOUSE_BUTTON and not codex.bindings.E)
codexPress("CONTROL+E")
codexPress("DOWN_ARROW")
codexPress("LEFT_MOUSE_BUTTON")
assert(codex.violations == 0 and #codex.created == 0, "Key callbacks must only queue intents")
codexPoll()
assert(#codex.created == 0 and codexLogged(codex, "open the PDA first"), "Codex opened without a visible PDA")
assert(codex.book.button.visibility == 1, "Archive button was shown while the PDA was closed")

codex.pdaVisible = true
codexPoll()
assert(#codex.created == 21 and #codex.images == 35 and codexLogged(codex, "added to the PDA Archive tab"), "Codex did not claim the Archive tab")
assert(codexLogged(codex, "text language uk: "), "Codex text was not localized on the game thread")
local codexPage = codexPageWidgets(codex, 1, 1)
assert(#codex.book.root.children == 63 and codex.book.placeholder.visibility == 1, "Placeholder was not replaced")
assert(codex.book.button.visibility == 0 and codex.book.button.enabled == true, "Archive button was not shown")
assert(codexPage.tabs[1].label.text == "Artifacts" and codexPage.tabs[1].label.TextSettings.FontStyleId:ToString() == "PDACurrQuestBtn")
assert(codexPage.tabs[1].idleLabel.text == "Artifacts" and codexPage.tabs[1].idleLabel.TextSettings.FontStyleId:ToString() == "PDAQuestDetails")
assert(codexPage.title.TextSettings.FontStyleId:ToString() == "PDAQuestDetailsNameMain" and codexPage.title.bEnableStyleManager == true)
assert(codexPage.tabs[1].background.visibility == 0 and codexPage.tabs[1].label.visibility == 3, "Tab backgrounds must take the clicks")
assert(codexPage.rows[1].hover.visibility == 3 and codexPage.rows[1].name.visibility == 3, "Row wheel catchers must take the clicks")
-- Tabs are W_PDAUpgradesButton's rounded T_button_side caps around a tinted middle, label centred.
assert(codexPage.tabs[2].leftCap.slot.padding.Left == 264 and codexPage.tabs[2].leftCap.brush and codexPage.tabs[2].leftCap.Brush.ImageSize.X == 5)
assert(codexPage.tabs[2].background.slot.padding.Left == 269 and codexPage.tabs[2].background.Brush.ImageSize.X == 222)
assert(codexPage.tabs[2].rightCap.slot.padding.Left == 491 and codexPage.tabs[2].rightCap.renderScale.X == -1)
local codexTabBox = codexPage.tabs[2].label.parent
assert(codexTabBox.width == 232 and codexTabBox.height == 50 and codexTabBox.slot.padding.Left == 264 and codexTabBox.visibility == 4)
assert(codexPage.tabs[2].label.slot.horizontal == 2 and codexPage.tabs[2].label.slot.vertical == 2, "Tab labels were not centred")
assert(codexPage.rows[2].hover.slot.padding.Top == 162 and codexPage.rows[2].name.slot.padding.Top == 166 and codexPage.rows[2].name.slot.padding.Left == 94)
assert(codexPage.divider.brush and codexPage.divider.slot.horizontal == 0 and codexPage.body.clipping == 1 and codexPage.body.autoWrap == true)
-- The body scrolls in a W_PDANotesDetails-style ScrollBox: thin flat thumb, no edge shadows.
local codexDetailScroll = codex.wheels[7]
assert(codexPage.body.parent == codexDetailScroll and codexDetailScroll.visibility == 0 and codexDetailScroll.ConsumeMouseWheel == 1)
assert(codexDetailScroll.parent.width == 700 and codexDetailScroll.parent.maxHeight == 1 and codexDetailScroll.parent.slot.padding.Left == 544)
assert(codexDetailScroll.AllowOverscroll == false and codexDetailScroll.thickness.X == 3)
assert(codexDetailScroll.WidgetBarStyle.NormalThumbImage.DrawAs == 3 and codexDetailScroll.WidgetBarStyle.NormalThumbImage.TintColor.SpecifiedColor.A == 0.5)
assert(codexDetailScroll.WidgetBarStyle.DraggedThumbImage.TintColor.SpecifiedColor.A == 1 and codexDetailScroll.WidgetStyle.TopShadowBrush.DrawAs == 0)
assert(codexPage.picture.visibility == 1, "The picture showed before any entry")
assert(codexPage.title.text == nil and codex.countReads == 0, "Codex rendered while its tab was inactive")
assert(codexPage.title.layer == nil, "Archive widgets were added to the viewport")

codex.book.button.visibility, codex.book.button.enabled = 1, false
codexPoll()
assert(codex.book.button.visibility == 0 and codex.book.button.enabled == true, "Archive button was not re-shown")
codexPress("DOWN_ARROW")
codexPoll()
assert(codexPage.title.text == nil, "Navigation acted while the Archive tab was inactive")

codex.activePage = 6
codexPoll()
assert(codexPage.status.text == "Artifacts     1-6 of 8   |   carrying 1 of 8" and codexPage.controls.text:find("Q/E: PDA pages", 1, true))
assert(isSelectedTab(codexPage.tabs[1]) and isIdleTab(codexPage.tabs[2]), "Tabs were not styled like the Upgrades buttons")
assert(takeSounds(codex) == "", "Opening the Archive tab played a navigation sound")
assert(codexPage.rows[1].name.text == "Artifact 1" and codexPage.rows[1].subtitle.text == "Thermal")
assert(codexPage.rows[2].subtitle.text == "Carried x3  |  Thermal")
assert(codexPage.rows[1].selected.visibility == 3 and codexPage.rows[2].selected.visibility == 1)
assert(codexPage.title.text == "Artifact 1" and codexPage.subtitle.text == "Artifacts")
assert(codexPage.body.text:find("^Anomaly: Thermal\nCarried now: 0\n\nEffects:\n%- Radiation %+1\n") and not codexPage.body.text:find("for more", 1, true), "The scroll panel did not take the whole body")
assert(codexPage.controls.text == "Click, wheel or arrows: browse     PgUp/PgDn: page     Q/E: PDA pages")
assert(codexPage.picture.visibility == 3 and codexPage.picture.Brush.ImageSize.X == 520 and codexPage.picture.Brush.ImageSize.Y == 260)
assert(codexPage.picture.slot.padding.Left == 1268 and codexPage.picture.slot.padding.Top == 220, "The picture did not sit beside the text")
assert(codexDetailScroll.parent.slot.padding.Top == 185 and codexPage.icon.color.R == 1, "Unmasked icons were tinted")
assert(codexPage.rows[1].icon.visibility == 3 and codexPage.rows[1].icon.Brush.ImageSize.X == 64 and codexPage.rows[1].icon.slot.padding.Top == 114)
assert(codexPage.rows[2].icon.visibility == 1 and codexLogCount(codex, "texture unavailable: /Game/Missing.Missing") == 1)
assert(codexPage.icon.Brush.ImageSize.X == 128 and codexPage.icon.Brush.ImageSize.Y == 64 and codexPage.icon.slot.padding.Top == 57)
assert(codexPage.iconBox.visibility == 3 and codexPage.title.slot.padding.Left == 696, "Title did not make room for the icon")
local codexReads = codex.countReads
codexPoll()
assert(codex.countReads == codexReads, "Counts were re-read before RefreshSeconds elapsed")

local codexRowWheels = {}
for row = 1, 6 do codexRowWheels[row] = codex.wheels[row] end
assert(codexRowWheels[1].offset == 2000 and codexRowWheels[1].ConsumeMouseWheel == 1 and codexRowWheels[1].visibility == 0)
assert(codexRowWheels[2].parent.width == 505 and codexRowWheels[2].parent.height == 64 and codexRowWheels[2].parent.slot.padding.Top == 162)
codexRowWheels[3].offset = 2032
codexPoll()
assert(codexPage.status.text:find("3-8 of 8", 1, true) and codexPage.title.text == "Artifact 1", "Wheel did not scroll the list window")
assert(codexRowWheels[3].offset == 2000, "Wheel catcher was not re-armed")
assert(takeSounds(codex) == "", "List wheel played a sound; Upgrades scrolling is silent")
codexRowWheels[1].offset = 0
codexPoll()
assert(codexPage.status.text:find("3-8 of 8", 1, true) and codexRowWheels[1].offset == 2000, "A layout reset was read as wheel input")
assert(takeSounds(codex) == "", "A layout reset played a sound")
-- The detail panel scrolls natively; refreshes of the same entry keep the reader's place.
codexRowWheels[1].offset = 1968
codexDetailScroll.offset = 120
codexPoll()
assert(codexPage.status.text:find("1-6 of 8", 1, true) and codexDetailScroll.offset == 120, "Wheel did not scroll back or the detail lost its place")
assert(takeSounds(codex) == "", "Detail wheel played a sound; Upgrades scrolling is silent")

codexPress("DOWN_ARROW", 6)
codexPoll()
assert(takeSounds(codex) == "SFX_UI_Upgrade_Switch", "Selection change did not play the Upgrades select sound once")
assert(codexPage.status.text:find("2-7 of 8", 1, true) and codexPage.rows[1].name.text == "Artifact 2")
assert(codexPage.rows[6].selected.visibility == 3 and codexPage.rows[1].selected.visibility == 1 and codexPage.title.text == "Artifact 7")
codexPress("PAGE_DOWN")
codexPoll()
assert(codexPage.status.text:find("3-8 of 8", 1, true) and codexPage.rows[6].name.text == "Artifact 8")
codexPress("PAGE_UP")
codexPoll()
assert(codexPage.status.text:find("2-7 of 8", 1, true) and codexPage.body.text:find("Carried now: 3", 1, true))
assert(codexPage.subtitle.text == "Artifacts  |  Carried: 3" and codexPage.iconBox.visibility == 1)
assert(codexPage.title.slot.padding.Left == 544, "Title kept the icon gap for an entry without an icon")
assert(codexPage.picture.visibility == 1, "An entry without a render kept the last picture")
assert(codexLogCount(codex, "texture unavailable: /Game/Missing.Missing") == 1, "A missing texture was retried")

-- Slate marks the whole hit path hovered, so the catcher's SizeBox alone also counts.
codexRowWheels[3].parent.hovered = true
codexPoll()
assert(codexPage.rows[3].hover.color.A == 0.6, "Hovered row was not highlighted")
codexPress("LEFT_MOUSE_BUTTON")
codexPoll()
codexRowWheels[3].parent.hovered = false
codexPoll()
assert(codexPage.title.text == "Artifact 4" and codexPage.rows[3].selected.visibility == 3, "Row click did not select")
assert(codexPage.rows[3].hover.color.A == 0, "Row highlight outlived the hover")
codexPress("LEFT_MOUSE_BUTTON")
codexPoll()
assert(codexPage.title.text == "Artifact 4", "A click outside the codex changed the selection")
codexRowWheels[2].hovered = true
codexPoll()
codexRowWheels[2].hovered = false
codexPress("LEFT_MOUSE_BUTTON")
codexPoll()
assert(codexPage.title.text == "Artifact 3", "A press that cleared the hover lost the click")
codexRowWheels[3].hovered = true
codexPoll()
codexRowWheels[3].hovered = false
codex.activePage = 2
codexPoll()
codex.activePage = 6
codexPress("LEFT_MOUSE_BUTTON")
codexPoll()
assert(codexPage.title.text == "Artifact 3", "A hover from before leaving the Archive tab caught a later click")
assert(codexLogged(codex, "click matched no tab or row (cursor 300,200; hover root=0 detail=0 tabs=00 rowWheels=000000 rowBoxes=000000 rowImages=000000)"), "A missed click was not logged with its hover report")
codexPress("DOWN_ARROW", 3)
codexPress("UP_ARROW", 2)

codexDetailScroll.offset = 90
codexPress("UP_ARROW", 3)
codexPoll()
assert(codexPage.title.text == "Artifact 1" and codexDetailScroll.offset == 0, "A new entry did not start at the top")
codexPress("OEM_SIX")
codexPoll()
assert(codexDetailScroll.offset == 240 and codexPage.body.text:find("^Anomaly: Thermal\n"), "] did not scroll the panel")
codexPress("OEM_SIX")
codexPoll()
assert(codexDetailScroll.offset == 300, "] scrolled past the end")
codexPress("OEM_FOUR")
codexPoll()
assert(codexDetailScroll.offset == 60, "[ did not scroll back")
takeSounds(codex)

codexPage.tabs[2].background.hovered = true
codexPress("LEFT_MOUSE_BUTTON")
codexReads = codex.countReads
codexPoll()
codexPage.tabs[2].background.hovered = false
assert(isSelectedTab(codexPage.tabs[2]) and isIdleTab(codexPage.tabs[1]), "Tab click did not switch")
assert(takeSounds(codex) == "SFX_PDA_JournalTabSwitch", "Tab click did not play only the tab switch sound")
assert(codexPage.status.text == "Factions     1-1 of 1" and codex.countReads == codexReads)
assert(codexPage.body.text == "Freedom fights for the\nZone.\n\nStarting standing: Enemy\n\nStance toward others:\n- Duty: Enemy\n- Monolith: Enemy of\n  everyone", "Lore did not lead the faction detail")
assert(codexPage.title.text == "Svoboda" and codexPage.rows[1].name.text == "Svoboda", "Faction name was not localized")
assert(codexPage.rows[2].name.text == "" and codexPage.rows[2].subtitle.text == "")
-- Faction badges are white masks, tinted like the game's own badge art.
assert(codexPage.rows[1].icon.visibility == 3 and codexPage.rows[1].icon.color.R < 1 and codexPage.icon.color.R < 1, "Badges were not tinted")
assert(codexPage.iconBox.visibility == 3 and codexPage.picture.visibility == 1)
codexRowWheels[2].hovered = true
codexPoll()
codexRowWheels[2].hovered = false
assert(codexPage.rows[2].hover.color.A == 0, "An empty row was highlighted")
codexPress("RIGHT_ARROW")
codex.inventory.Art1 = 1
codexPoll()
assert(isSelectedTab(codexPage.tabs[1]) and codexPage.rows[1].subtitle.text == "Carried x1  |  Thermal")
codex.inventory.Art1 = 2
codex.now = codex.now + 1
codexPoll()
assert(codexPage.rows[1].subtitle.text == "Carried x1  |  Thermal", "Counts refreshed before RefreshSeconds")
codex.now = codex.now + 1
codexPoll()
assert(codexPage.rows[1].subtitle.text == "Carried x2  |  Thermal", "Counts did not refresh after RefreshSeconds")

codex.countFailure = true
codex.now = codex.now + 2
codexPoll()
assert(codexPage.status.text:find("carried counts unavailable", 1, true) and codexPage.body.text:find("Carried now: unknown", 1, true))
assert(codexLogged(codex, "inventory ERROR: unexpected count for Art1: nil"))
codex.countFailure = false
codex.now = codex.now + 2
codexPoll()
assert(codexPage.status.text:find("carrying 2 of 8", 1, true), "Counts did not recover after a failed read")

for index = #codex.logs, 1, -1 do
    if codex.logs[index]:find("inventory ERROR", 1, true) then table.remove(codex.logs, index) end
end

codexPress("CONTROL+E")
codexPoll()
assert(#codex.created == 21 and codexLogged(codex, "Ctrl+E is only the fallback"), "Ctrl+E opened a second codex")
codex.pdaVisible = false
codexPoll()
assert(not codexPage.title.removed, "Archive page widgets were removed when the PDA closed")

codex.pdaVisible = true
codex.created[5]:RemoveFromParent()
codex.created[5].destroyed = true
codexPoll()
assert(codexPage.title.removed and codexPage.rows[1].hover.removed and codexLogCount(codex, "will re-add them") == 1)
codex.now = codex.now + 1
codexPoll()
assert(#codex.created == 42 and #codex.book.root.children == 63, "Codex did not re-add destroyed Archive widgets")

local oldBook = codex.book
codex.book = codex.makeBook("/Game/PDA2")
codex.notify(codex.book)
oldBook.BestiaryPage.destroyed = true
codexPoll()
assert(codexLogCount(codex, "will re-add them") == 2, "Lost Archive page was not released")
assert(#codex.created == 63 and #codex.images == 105 and #codex.book.root.children == 63, "Codex did not claim the new PDA's Archive tab")
codex:check()

local plainCodex = codexFixture({ ArchiveRows = 6, VisibleRows = 6 }, nil, { noImages = true })
plainCodex.pdaVisible, plainCodex.activePage = true, 6
plainCodex:run(plainCodex.timers[1].callback)
assert(#plainCodex.created == 21 and #plainCodex.images == 0 and codexLogged(plainCodex, "Archive images unavailable"))
assert(codexLogged(plainCodex, "centred labels unavailable") and plainCodex.created[1].slot.padding.Left == 18, "Labels did not fall back to a left inset")
assert(plainCodex.created[1].visibility == 0 and plainCodex.created[2].visibility == 1, "Text-only tabs did not show only the selected label")
assert(plainCodex.created[7].visibility == 0 and plainCodex.created[8].visibility == 3)
plainCodex.created[7].hovered = true
plainCodex.bindings.LEFT_MOUSE_BUTTON()
plainCodex:run(plainCodex.timers[1].callback)
assert(plainCodex.created[17].text == "Artifact 2", "Text-only rows did not take clicks")
plainCodex:check()

local foreignCodex = codexFixture({ VisibleRows = 6 }, "button")
local function foreignPoll() foreignCodex:run(foreignCodex.timers[1].callback) end
foreignCodex.pdaVisible = true
foreignPoll()
foreignPoll()
assert(#foreignCodex.created == 0 and #foreignCodex.book.root.children == 1, "Codex took an Archive tab owned by another mod")
assert(codexLogCount(foreignCodex, "already shown by another mod; ZoneCodex stays on Ctrl+E instead") == 1)
foreignCodex.bindings["CONTROL+E"]()
foreignPoll()
local codexViewport = codexWidgets(foreignCodex)
assert(#foreignCodex.created == 10 and codexViewport.header.layer == 1000, "Ctrl+E fallback did not open")
assert(codexViewport.header.visibility == 4 and codexViewport.tabs[1].visibility == 4 and codexViewport.rows[1].visibility == 4)
assert(codexViewport.header.position.X == 260 and codexViewport.header.position.Y == 424)
assert(codexViewport.rows[1].position.X == 504 and codexViewport.rows[1].position.Y == 500 and codexViewport.rows[1].size.X == 400)
assert(codexViewport.detail.position.X == 928 and codexViewport.header.text:find("Ctrl+E close", 1, true))
assert(codexViewport.header.text:find("^ZONE CODEX   |   Artifacts   |   1%-6 of 8   |   carrying 1 of 8\n"))
assert(codexViewport.tabs[1].text == "> Artifacts" and codexViewport.rows[2].text == "   Artifact 2  x3")
assert(codexViewport.detail.text == "Artifact 1\n\nAnomaly: Thermal\nCarried now: 0\n\n...  ] for more")
codexViewport.rows[2].hovered = true
foreignCodex.bindings.LEFT_MOUSE_BUTTON()
foreignPoll()
assert(codexViewport.rows[1].text == "> Artifact 1", "Viewport fallback took a click")
foreignCodex.bindings.DOWN_ARROW()
foreignPoll()
assert(codexViewport.rows[2].text == "> Artifact 2  x3", "Viewport fallback did not navigate")
foreignCodex.pdaVisible = false
foreignPoll()
assert(codexViewport.header.removed and codexViewport.rows[6].removed and codexLogged(foreignCodex, "closed: PDA closed"))
foreignCodex.pdaVisible = true
foreignCodex.bindings["CONTROL+E"]()
foreignPoll()
assert(#foreignCodex.created == 20, "Fallback did not reopen")
foreignCodex.created[15].destroyed = true
foreignPoll()
assert(codexLogged(foreignCodex, "codex widgets were destroyed"), "Destroyed widgets did not close the codex")
foreignCodex.bindings["CONTROL+E"]()
foreignPoll()
assert(#foreignCodex.created == 30)
foreignCodex.bindings["CONTROL+E"]()
foreignPoll()
assert(foreignCodex.created[21].removed and foreignCodex.created[30].removed, "Ctrl+E did not close the fallback")
foreignCodex:check()

local filledCodex = codexFixture({ VisibleRows = 6 }, "page")
filledCodex.pdaVisible = true
filledCodex:run(filledCodex.timers[1].callback)
assert(#filledCodex.created == 0 and codexLogged(filledCodex, "Archive page already has content from another mod"))
assert(filledCodex.book.button.visibility == 1, "Codex showed another mod's Archive button")
filledCodex:check()

local ungatedCodex = codexFixture({ Key = "NOT_A_KEY", Modifier = "hyper", RequirePda = false, UseArchiveTab = false, VisibleRows = 6 })
assert(codexLogged(ungatedCodex, "unknown Key 'NOT_A_KEY'") and codexLogged(ungatedCodex, "unknown Modifier 'HYPER'"))
ungatedCodex.bindings["CONTROL+E"]()
ungatedCodex:run(ungatedCodex.timers[1].callback)
assert(#ungatedCodex.created == 10 and ungatedCodex.created[1].layer == 1000, "Ungated fallback did not open")
ungatedCodex.pdaVisible = true
ungatedCodex:run(ungatedCodex.timers[1].callback)
assert(#ungatedCodex.book.root.children == 1 and #ungatedCodex.created == 10, "UseArchiveTab = false still claimed the tab")
ungatedCodex:check()

local plainKeyCodex = codexFixture({ Modifier = "" })
assert(plainKeyCodex.bindings.E and codexLogged(plainKeyCodex, "or E as a fallback"), "Empty Modifier did not bind the bare key")
plainKeyCodex:check()
print("PASS: ZoneCodex styles the PDA Archive tab like the Upgrades page, backs off from other Archive mods, handles clicks, hover and keys, and keeps a Ctrl+E fallback")
