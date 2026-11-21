-- Input queues plain data; all UObject access stays on the game-thread poll.
local Catalog = require("catalog")
local HintBar = require("hint_bar")
local MCM = require("mcm")
local Textures = require("texture_catalog")
local Toast = require("toast")
local Unreal = require("unreal")
local WorldMap = require("world_map")

assert(type(LoopInGameThreadWithDelay) == "function", "ZoneAtlas requires UE4SS LoopInGameThreadWithDelay")

local source = debug and debug.getinfo and debug.getinfo(1, "S").source or ""

Catalog.load(source:match("^@(.*)[\\/][Ss]cripts[\\/][^\\/]+$") or "ue4ss\\Mods\\ZoneAtlas")

local config, entries = Catalog.config, Catalog.entries

Unreal.log(
    string.format(
        "%d map(s); key %s (Shift = back); starting on '%s'",
        #entries,
        config.Key,
        entries[Catalog.selected].name
    )
)

local clicked, pendingDirection, pendingSeen = false, nil, false
local key = Key[config.Key]

if not key then
    Unreal.log("unknown Key '" .. config.Key .. "' in config.lua; using F6")
    key, config.Key = Key.F6, "F6"
end

RegisterKeyBind(key, function()
    pendingDirection = pendingDirection or 1
end)

local shiftOk, shiftError = pcall(function()
    RegisterKeyBind(key, { ModifierKey.SHIFT }, function()
        pendingDirection = -1
    end)
end)

if not shiftOk then
    Unreal.log("reverse keybind unavailable: " .. tostring(shiftError))
end

if config.ShowHint then
    local clickOk, clickError = pcall(function()
        RegisterKeyBind(Key.LEFT_MOUSE_BUTTON, function()
            clicked = true
        end)
    end)

    if not clickOk then
        Unreal.log("hint click keybind unavailable: " .. tostring(clickError))
    end
end

local function step(direction, now, quiet)
    for _ = 1, #entries do
        Catalog.selected = (Catalog.selected - 1 + direction) % #entries + 1

        if Catalog.inCycle(entries[Catalog.selected]) and Textures.usable(entries[Catalog.selected]) then
            break
        end
    end

    Catalog.save()
    Unreal.log("map -> " .. entries[Catalog.selected].name)

    if not quiet then
        local position, total = 0, 0

        for index, entry in ipairs(entries) do
            if Catalog.inCycle(entry) then
                total = total + 1
                position = index == Catalog.selected and total or position
            end
        end

        Toast.show(string.format("%s  (%d/%d)", entries[Catalog.selected].name, position, total), now)
    end
end

local appliedPath, fights, warnedFight = nil, 0, false
local errors = {}

local function run(name, callback, now)
    local ok, errorMessage = pcall(callback, now)

    if not ok and tostring(errorMessage) ~= errors[name] then
        errors[name] = tostring(errorMessage)
        Unreal.log(name .. " ERROR: " .. errors[name])
    end

    return ok
end

local function tick(now)
    if WorldMap.scene and not Unreal.isValid(WorldMap.scene) then
        HintBar.drop()
        WorldMap.reset()
        Toast.hide()
    end

    Toast.tick(now)
    local previousEnabled = Catalog.enabled
    run("mcm", MCM.tick, now)

    if Catalog.enabled ~= previousEnabled and not Catalog.inCycle(entries[Catalog.selected]) then
        step(1, now, true)
    end

    run("hint", HintBar.tick, now)
    
    local scene = WorldMap.findScene(now)
    local material = scene and WorldMap.material(scene)
    local currentTexture = material and material:K2_GetTextureParameterValue(FName("MapTexture"))
    local currentPath = Unreal.isValid(currentTexture) and Unreal.objectPath(currentTexture) or nil

    if currentPath and not Catalog.ownedPaths[currentPath] and currentPath ~= Catalog.gameDefaultPath then
        Catalog.gameDefaultPath = currentPath
        Unreal.log("game map texture: " .. currentPath)
    end

    -- One grace tick lets Shift+key override a simultaneous plain-key callback.
    local direction = pendingSeen and pendingDirection or nil

    if direction then
        pendingDirection, pendingSeen = nil, false
    else
        pendingSeen = pendingDirection ~= nil
    end

    if clicked then
        clicked = false
        direction = direction or (HintBar.isHovered() and 1 or nil)
    end

    if direction then
        local enabledCount = 0

        for _, entry in ipairs(entries) do
            enabledCount = enabledCount + (Catalog.inCycle(entry) and 1 or 0)
        end

        if enabledCount < 2 then
            Unreal.log("only one map in the cycle; nothing to switch (tick more in MCM)")
        elseif not config.OnlyWhenMapOpen or (scene and WorldMap.isOpen(scene)) then
            step(direction, now)
        end
    end

    if not material then
        return
    end

    local desiredTexture, desiredPath = Textures.desired(entries[Catalog.selected])

    if desiredTexture and desiredPath ~= currentPath then
        material:SetTextureParameterValue(FName("MapTexture"), desiredTexture)
        WorldMap.refreshCapture(scene)
        fights = appliedPath == desiredPath and fights + 1 or 0

        if fights >= 20 and not warnedFight then
            warnedFight = true
            Unreal.log("the game keeps resetting MapTexture; the swap may flicker")
        end

        if appliedPath ~= desiredPath then
            appliedPath = desiredPath
            Unreal.log("applied " .. entries[Catalog.selected].name)
        end
    end
end

LoopInGameThreadWithDelay(100, function()
    if not run("poll", tick, os.clock()) then
        WorldMap.scene = nil
    end

    return false
end)
