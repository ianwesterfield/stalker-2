local root = arg[1] or "Gaming/stalker-2"

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
        RegisterKeyBind = function() end,
        Key = {}, ModifierKey = {},
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
        io = { open = function() error("Unexpected flag write") end },
    }, { __index = _G })
    local path = root .. "/ue4ss-mods/" .. name .. "/Scripts/main.lua"
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

local zone = loadMod("ZoneXM")
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