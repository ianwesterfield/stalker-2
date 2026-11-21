local Banner = require("banner")
local Bridge = require("bridge")
local Sensors = require("sensors")
local Unreal = require("unreal")

local POLL_MS = 250
local VERSION = "1.0.1"

assert(type(LoopInGameThreadWithDelay) == "function", "ZoneXM requires UE4SS LoopInGameThreadWithDelay")

Sensors.start()

LoopInGameThreadWithDelay(POLL_MS, function()
    local now = os.time()
    local playerController = Sensors.poll(now * 1000)
    Banner.tick(now, playerController)

    return false
end)

Unreal.log("v" .. VERSION .. " loaded (flag: " .. Bridge.ALERT_PATH .. ")")
