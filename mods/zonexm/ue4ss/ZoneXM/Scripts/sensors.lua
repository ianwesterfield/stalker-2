local Bridge = require("bridge")
local UEHelpers = require("UEHelpers")
local Unreal = require("unreal")

local Sensors = {}

local BEAST_HOLDOFF_MS = 3000
local BEAST_RADIUS = 3500
local BEAST_SWEEP_MS = 750
local DANGER_RADIUS = 6000
local HEARTBEAT_MS = 3000
local HOLDOFF_MS = 6000
local TALK_HOLDOFF_MS = 2500

-- One sensor state per UE4SS mod Lua state; hooks and timers run on the game thread.
local beastCount = 0
local hitCount = 0
local lastBeastAt = 0
local lastHitAt = 0
local lastTalkAt = 0
local radarLogs = 0
local rawByFunction = {}
local talkCount = 0

local dialogDetected = false
local flagWritten
local lastHeartbeatAt = 0
local writes = 0

local function nearPlayer(source)
    local playerPawn
    pcall(function()
        playerPawn = UEHelpers.GetPlayerController().Pawn
    end)

    if not (playerPawn and playerPawn:IsValid()) then
        return false
    end

    local playerLocation
    pcall(function()
        playerLocation = playerPawn:K2_GetActorLocation()
    end)

    if not playerLocation then
        return true -- Unknown distance conservatively counts as nearby.
    end

    local sourceLocation
    pcall(function()
        sourceLocation = source:K2_GetActorLocation()
    end)

    if not sourceLocation then
        pcall(function()
            sourceLocation = source:GetOwner():K2_GetActorLocation()
        end)
    end

    if not sourceLocation then
        return true -- Component dispatchers may not expose an actor location.
    end

    local deltaX = sourceLocation.X - playerLocation.X
    local deltaY = sourceLocation.Y - playerLocation.Y
    local deltaZ = sourceLocation.Z - playerLocation.Z

    return deltaX * deltaX + deltaY * deltaY + deltaZ * deltaZ <= DANGER_RADIUS * DANGER_RADIUS
end

local function registerHooks(functionPaths, onNearby)
    for _, functionPath in ipairs(functionPaths) do
        local functionName = functionPath:match(":([^:]+)$")
        local armed, hookError = pcall(function()
            RegisterHook(functionPath, function(context)
                Unreal.attempt(functionName, function()
                    local source = context:get()

                    if not (source and source:IsValid()) then
                        return
                    end

                    local count = (rawByFunction[functionName] or 0) + 1
                    rawByFunction[functionName] = count

                    if count <= 3 then
                        Unreal.log(functionName .. " fired raw (#" .. count .. ")")
                    end

                    if nearPlayer(source) then
                        onNearby(functionName)
                    end
                end)
            end)
        end)

        Unreal.log("hook " .. functionName .. (armed and " armed" or (" FAILED: " .. tostring(hookError))))
    end
end

local function sweepMutants()
    local playerController = UEHelpers.GetPlayerController()
    local playerPawn = playerController and playerController.Pawn

    if not (playerPawn and playerPawn:IsValid()) then
        return
    end

    local playerLocation = playerPawn:K2_GetActorLocation()
    local found = false

    for _, animationInstance in ipairs(FindAllOf("AnimInstanceMutant") or {}) do
        Unreal.attempt("mutant location", function()
            local mutant = animationInstance:GetOwningActor()

            if not (mutant and mutant:IsValid() and mutant:IsAlive()) then
                return
            end

            local location = mutant:K2_GetActorLocation()
            local deltaX = location.X - playerLocation.X
            local deltaY = location.Y - playerLocation.Y
            local deltaZ = location.Z - playerLocation.Z
            local distanceSquared = deltaX * deltaX + deltaY * deltaY + deltaZ * deltaZ

            if distanceSquared <= BEAST_RADIUS * BEAST_RADIUS then
                lastBeastAt = os.time() * 1000
                found = true

                if radarLogs < 3 then
                    radarLogs = radarLogs + 1
                    Unreal.log(
                        string.format(
                            "beast in sphere: %s at %.0fm",
                            mutant:GetClass():GetFName():ToString(),
                            math.sqrt(distanceSquared) / 100
                        )
                    )
                end
            end
        end)

        if found then
            break
        end
    end
end

function Sensors.start()
    -- These are the proven VM dispatches; broad per-contact hooks can peg the game thread.
    registerHooks({ "/Script/Stalker2.ItemAppearanceComponent:OnShotSoundStart" }, function(functionName)
        lastHitAt = os.time() * 1000
        hitCount = hitCount + 1

        if hitCount <= 3 then
            Unreal.log("combat near Skif (#" .. hitCount .. ") via " .. functionName)
        end
    end)

    registerHooks({
        "/Script/Stalker2.Obj:OnMeleeAttack_BP",
        "/Script/Stalker2.Obj:MakeAttack_BP",
    }, function(functionName)
        lastBeastAt = os.time() * 1000
        beastCount = beastCount + 1

        if beastCount <= 3 then
            Unreal.log("melee near Skif (#" .. beastCount .. ") via " .. functionName)
        end
    end)

    LoopInGameThreadWithDelay(BEAST_SWEEP_MS, function()
        Unreal.attempt("mutant radar", sweepMutants)
        return false
    end)
end

---@param nowMilliseconds number
function Sensors.poll(nowMilliseconds)
    -- Visible subtitles cover dialogue, barks and cutscenes; this tier needs subtitles enabled.
    Unreal.attempt("speech sensor", function()
        local subtitles = FindFirstOf("SubtitleView")

        if subtitles and subtitles:IsValid() and subtitles:IsVisible() then
            lastTalkAt = nowMilliseconds
            talkCount = talkCount + 1

            if talkCount <= 3 then
                Unreal.log("subtitles visible: someone's talking (#" .. talkCount .. ")")
            end
        end
    end)

    local playerAlive = false
    local playerController

    Unreal.attempt("player sensor", function()
        playerController = UEHelpers.GetPlayerController()
        playerAlive = playerController and playerController:IsValid() or false

        if playerAlive and playerController:IsInStaticDialog() then
            lastTalkAt = nowMilliseconds

            if not dialogDetected then
                Unreal.log("static dialog detected (queryable works)")
                dialogDetected = true
            end
        end
    end)

    if not playerAlive then
        lastBeastAt, lastHitAt, lastTalkAt = 0, 0, 0
    end

    local isAlert = (lastHitAt > 0 and nowMilliseconds - lastHitAt < HOLDOFF_MS)
        or (lastTalkAt > 0 and nowMilliseconds - lastTalkAt < TALK_HOLDOFF_MS)
        or (lastBeastAt > 0 and nowMilliseconds - lastBeastAt < BEAST_HOLDOFF_MS)
    local previousFlag = flagWritten

    if isAlert then
        if not flagWritten or nowMilliseconds - lastHeartbeatAt >= HEARTBEAT_MS then
            local written = Unreal.attempt("alert flag write", Bridge.writeAlert)

            if written then
                lastHeartbeatAt = nowMilliseconds

                if not flagWritten then
                    writes = writes + 1
                end

                flagWritten = true
            end
        end
    elseif flagWritten then
        local removed = Unreal.attempt("alert flag removal", Bridge.clearAlert)

        if removed then
            flagWritten = false
            writes = writes + 1
        end
    else
        flagWritten = false
    end

    if writes <= 4 and flagWritten ~= previousFlag then
        Unreal.log("alert -> " .. (flagWritten and "DANGER" or "clear"))
    end

    return playerController
end

return Sensors
