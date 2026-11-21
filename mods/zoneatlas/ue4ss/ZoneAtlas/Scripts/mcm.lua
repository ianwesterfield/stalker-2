local Catalog = require("catalog")
local Unreal = require("unreal")

local MCM = {}
local fields = {
    bool = "BoolValue_18_561E7B474E51CDC6C657A89251AA5995",
    id = "SettingID_20_5CDB958A4AF1113D73FA76BF15153E78",
    mod = "ModID_19_16F2EB904B3610C78A68FE94C1064C9B",
}
local parameterOrder = {
    "ModID",
    "SettingID",
    "SettingHoverText",
    "ModHeaderTexture",
    "AuthorName",
    "Category",
    "CategoryHeaderTexture",
    "Type",
    "BoolValue",
    "IntValue",
    "FloatValue",
    "FloatControllerStepValue",
    "StringValue",
    "TransformValue",
    "VectorValue",
    "RotatorValue",
    "ComboBoxOptions",
    "ComboBoxSelectedOption",
    "Keybind",
    "ButtonText",
}
local state = { errors = 0, nextFind = 0, params = {} }

local function settingValues(name, nullObject)
    return {
        AuthorName = "ZoneAtlas",
        BoolValue = true,
        ButtonText = "",
        Category = "Maps in the cycle",
        CategoryHeaderTexture = nullObject,
        ComboBoxOptions = { "" },
        ComboBoxSelectedOption = 0,
        FloatControllerStepValue = 0.0,
        FloatValue = 0.0,
        IntValue = 0,
        Keybind = "",
        ModHeaderTexture = nullObject,
        ModID = "ZoneAtlas",
        RotatorValue = { Pitch = 0, Yaw = 0, Roll = 0 },
        SettingHoverText = "Include this map when cycling map styles with " .. Catalog.config.Key .. " on the PDA map.",
        SettingID = name,
        StringValue = "",
        TransformValue = {
            Rotation = { X = 0, Y = 0, Z = 0, W = 1 },
            Scale3D = { X = 1, Y = 1, Z = 1 },
            Translation = { X = 0, Y = 0, Z = 0 },
        },
        Type = 0,
        VectorValue = { X = 0, Y = 0, Z = 0 },
    }
end

local function reflectParameters(manager, functionName)
    local known = {}

    for _, name in ipairs(parameterOrder) do
        known[name] = true
    end

    local ok, names = pcall(function()
        local functionObject = StaticFindObject(Unreal.objectPath(manager:GetClass()) .. ":" .. functionName)

        if not Unreal.isValid(functionObject) then
            return nil
        end

        local names, reachedLocal = {}, false
        functionObject:ForEachProperty(function(property)
            if reachedLocal then
                return
            end

            local name = property:GetFName():ToString()
            local flagOk, isParameter = pcall(function()
                return property:HasAnyPropertyFlags(0x80) -- CPF_Parm
            end)

            if flagOk and type(isParameter) == "boolean" then
                if isParameter then
                    names[#names + 1] = name
                end
            elseif known[name] then
                names[#names + 1] = name
            else
                reachedLocal = true
            end
        end)

        return names
    end)

    if ok and names and #names > 0 then
        for _, name in ipairs(names) do
            if not known[name] then
                Unreal.log("MCM " .. functionName .. " has an unknown parameter '" .. name .. "'; using built-in order")
                return parameterOrder
            end
        end

        return names
    end

    return parameterOrder
end

local function registerSetting(manager, functionName, name)
    state.params[functionName] = state.params[functionName] or reflectParameters(manager, functionName)
    local order = state.params[functionName]

    local function call(nullObject)
        local arguments, values = {}, settingValues(name, nullObject)

        for index, parameterName in ipairs(order) do
            arguments[index] = values[parameterName]
        end

        manager[functionName](manager, table.unpack(arguments, 1, #order))
    end

    local ok, errorMessage = pcall(call)

    if not ok and type(CreateInvalidObject) == "function" then
        ok, errorMessage = pcall(call, CreateInvalidObject())
    end

    assert(ok, functionName .. ": " .. tostring(errorMessage))
end

local function readSettings(manager)
    if not state.fieldsRead then
        local ok, errorMessage = pcall(function()
            local struct = StaticFindObject("/ModConfigurationMenu/Structs/ST_MCM_ModSetting.ST_MCM_ModSetting")

            if Unreal.isValid(struct) then
                struct:ForEachProperty(function(property)
                    local name = property:GetFName():ToString()

                    for field, prefix in pairs({ bool = "BoolValue_", id = "SettingID_", mod = "ModID_" }) do
                        if name:sub(1, #prefix) == prefix then
                            fields[field] = name
                        end
                    end
                end)
            end
        end)

        if not ok then
            Unreal.log("MCM field reflection failed; using built-in fields: " .. tostring(errorMessage))
        end

        state.fieldsRead = true
    end

    local found = {}
    
    manager.AllSettings:ForEach(function(_, element)
        local setting = element:get()

        if setting[fields.mod]:ToString() == "ZoneAtlas" then
            found[setting[fields.id]:ToString()] = setting[fields.bool] == true
        end
    end)

    return found
end

local function sync(manager, now)
    local found = readSettings(manager)

    if now >= state.nextRegister then
        state.nextRegister = now + 5
        manager:AddUniqueModID("ZoneAtlas")
        local added = 0

        for _, entry in ipairs(Catalog.entries) do
            if found[entry.name] == nil then
                registerSetting(manager, "RegisterModSetting", entry.name)
                added = added + 1
            end

            if not state.defaultsRegistered then
                registerSetting(manager, "RegisterDefaultModSetting", entry.name)
            end
        end

        state.defaultsRegistered = true

        if added > 0 then
            Unreal.log(string.format("MCM: registered %d map setting(s) under 'ZoneAtlas'", added))
        end
    end

    local enabled, names = {}, {}

    for _, entry in ipairs(Catalog.entries) do
        if found[entry.name] ~= false then
            enabled[entry.name] = true
            names[#names + 1] = entry.name
        end
    end

    local signature = #names > 0 and table.concat(names, " | ") or "*"

    if signature ~= state.signature then
        state.signature = signature
        Catalog.enabled = #names > 0 and enabled or nil
        Unreal.log(Catalog.enabled and ("cycle (MCM): " .. signature) or "no maps ticked in MCM; cycling all of them")
    end
end

function MCM.tick(now)
    if not Catalog.config.UseMCM or state.disabled then
        return
    end

    if not Unreal.isValid(state.manager) then
        state.manager = nil

        if now < state.nextFind then
            return
        end

        state.nextFind = now + 5

        if not Unreal.isValid(StaticFindObject("/ModConfigurationMenu/BP_MCM_Manager.BP_MCM_Manager_C")) then
            return
        end

        for _, manager in ipairs(FindAllOf("BP_MCM_Manager_C") or {}) do
            if Unreal.isValid(manager) and not Unreal.isDefault(manager) then
                state.manager, state.readyAt, state.nextRegister = manager, now + 6, 0
                state.defaultsRegistered = false
                Unreal.log("MCM manager: " .. manager:GetFullName())
                break
            end
        end
    end

    if not state.manager or now < state.readyAt or now < (state.nextPoll or 0) then
        return
    end

    state.nextPoll = now + 1
    local ok, errorMessage = pcall(sync, state.manager, now)
    state.errors = ok and 0 or state.errors + 1

    if not ok then
        state.manager = nil
        state.disabled = state.errors >= 3

        if state.disabled then
            Catalog.enabled = nil
        end

        Unreal.log(
            "MCM: " .. tostring(errorMessage) .. (state.disabled and "; giving up -- every map cycles" or "; retrying")
        )
    end
end

return MCM
