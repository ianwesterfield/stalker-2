-- menuprobe.lua v8 — own-the-click (IsHovered + LMB) + deep slot identity dump.
--
-- Run:  dofile("ue4ss/Mods/MolotovFire/Scripts/menuprobe.lua")
-- Then: right-click the vodka, hover PROBE WRAP, CLICK it, close menu. Read the log.
--
-- v8 learnings applied:
--   * The entry BP has ZERO click handlers of its own — native code binds each row's
--     button delegates during menu population; our spawned row never gets bound and
--     Lua cannot AddDynamic. So we own the click: menu open + probeEntry:IsHovered()
--     (callable native UFunction) + LMB keybind = our click. Also hook the menu's
--     OnNoItemClick/OnItemClicked to see if unwired-row clicks route there.
--   * Slot identity: prior dumps only walked the BP's OWN props (that's why only
--     NewVar_0 showed) — walk the SUPER CHAIN for props+functions and read the
--     ItemImage brush deeply.

local function log(msg) print("[menuprobe] " .. msg .. "\n") end
log("armed v8 - right-click the vodka, hover+click PROBE WRAP (120s)")

local probeEntry = nil
local menuAlive = nil

local function clsName(o)
    local n = "?"
    pcall(function() n = o:GetClass():GetFullName() end)
    return n
end

-- ---------- deep slot dump: class chain props + function names ----------

local function chainDump(obj, tag)
    local cls
    pcall(function() cls = obj:GetClass() end)
    while cls and cls:IsValid() do
        local cn = cls:GetFullName()
        pcall(function()
            cls:ForEachProperty(function(p)
                local fname = p:GetFName():ToString()
                local ok, v = pcall(function() return obj[fname] end)
                local out = "<unreadable>"
                if ok then
                    local t = type(v)
                    if t == "number" or t == "string" or t == "boolean" then
                        out = tostring(v)
                    elseif t == "userdata" then
                        local tn = ""
                        pcall(function() tn = v:type() end)
                        if tn == "UScriptStruct" then
                            out = "<struct>"
                        else
                            local valid = false
                            pcall(function() valid = v:IsValid() end)
                            out = valid and ("<" .. clsName(v) .. ">") or "<invalid>"
                        end
                    elseif v == nil then
                        out = "nil"
                    end
                end
                log(string.format("  %s prop %s = %s", tag, fname, out))
            end)
        end)
        pcall(function()
            cls:ForEachFunction(function(f)
                log(string.format("  %s func %s", tag, f:GetFName():ToString()))
            end)
        end)
        local sup
        pcall(function() sup = cls:GetSuperStruct() end)
        if sup and sup:IsValid() and sup:GetFullName():find("UserWidget") then break end
        cls = sup
    end
end

local function brushDeep(slot)
    pcall(function()
        local img = slot.ItemImage
        if not (img and img:IsValid()) then log("  brush: no ItemImage") return end
        pcall(function()
            local b = img.Brush
            log("  brush struct present")
            for _, f in ipairs({ "ResourceObject", "ResourceName", "ImageSize", "ImageType", "DrawAs" }) do
                local ok, v = pcall(function() return b[f] end)
                if ok and v ~= nil then
                    local out
                    pcall(function() out = tostring(v and v.GetFullName and v:GetFullName() or (v.ToString and v:ToString()) or v) end)
                    log(string.format("    Brush.%s = %s", f, tostring(out)))
                end
            end
        end)
        pcall(function()
            local b2 = img:GetBrush()
            local r = b2.ResourceObject
            if r and r:IsValid() then log("    GetBrush().ResourceObject = " .. r:GetFullName()) end
        end)
        pcall(function()
            local dyn = img:GetDynamicMaterial()
            if dyn and dyn:IsValid() then log("    GetDynamicMaterial = " .. dyn:GetFullName()) end
        end)
    end)
end

-- ---------- click ownership ----------

pcall(function()
    RegisterHook("/Script/Stalker2.RightClickMenuWidget:OnNoItemClick", function(self)
        pcall(function()
            local hov = false
            pcall(function() hov = probeEntry and probeEntry:IsValid() and probeEntry:IsHovered() end)
            log("menu OnNoItemClick fired (probe hovered=" .. tostring(hov) .. ")")
        end)
    end)
    RegisterHook("/Script/Stalker2.RightClickMenuWidget:OnItemClicked", function(self, data)
        pcall(function() log("menu OnItemClicked fired") end)
    end)
end)

local lmbOk = pcall(function()
    RegisterKeyBind(Key.LEFT_MOUSE_BUTTON, function()
        ExecuteInGameThread(function()
            pcall(function()
                if not (probeEntry and probeEntry:IsValid()) then return end
                local hov = probeEntry:IsHovered()
                if hov then
                    log(">>> LMB on PROBE WRAP (IsHovered=true) — THIS IS OUR CLICK <<<")
                else
                    log("LMB (probe not hovered)")
                end
            end)
        end)
    end)
end)
log("LMB keybind: " .. (lmbOk and "registered" or "Key.LEFT_MOUSE_BUTTON unavailable"))

-- ---------- menu open: identity + injection ----------

local function findInventory()
    for _, inv in ipairs(FindAllOf("InventoryNew") or {}) do
        if inv:IsValid() and not inv:GetFullName():find("Default__") then return inv end
    end
end

local dumpedSlot = false

pcall(function()
    NotifyOnNewObject("/Game/GameLite/FPS_Game/UIRemaster/Inventory/W_RightClickMenu.W_RightClickMenu_C", function(menu)
        menuAlive = menu
        ExecuteInGameThread(function()
            pcall(function()
                log("=== MENU OPEN ===")
                local inv = findInventory()
                if inv then
                    local slot
                    pcall(function() slot = inv.CurrClickedItem end)
                    local valid = false
                    if slot then pcall(function() valid = slot:IsValid() end) end
                    if valid then
                        brushDeep(slot)
                        if not dumpedSlot then
                            dumpedSlot = true
                            log("slot class chain dump:")
                            chainDump(slot, "slot")
                        end
                    end
                end
                ExecuteWithDelay(50, function()
                    ExecuteInGameThread(function()
                        pcall(function()
                            if not menu:IsValid() then return end
                            local itemClass
                            pcall(function() itemClass = menu.MenuItemWidgetClass end)
                            local box
                            pcall(function() box = menu.Menu end)
                            if not (itemClass and box and box:IsValid()) then return end
                            local wbl = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
                            local w = wbl:Create(menu, itemClass, nil)
                            if not (w and w:IsValid()) then return end
                            pcall(function() w.Label:SetText(FText("PROBE WRAP")) end)
                            pcall(function()
                                local src
                                for _, c in ipairs(box:GetAllChildren()) do
                                    local vis = false
                                    pcall(function() vis = c:IsVisible() end)
                                    if vis then src = c break end
                                end
                                if src then
                                    for _, p in ipairs({ "TextColorUnhovered", "TextColorHovered" }) do
                                        pcall(function()
                                            local s, d = src[p], w[p]
                                            d.SpecifiedColor.R = s.SpecifiedColor.R
                                            d.SpecifiedColor.G = s.SpecifiedColor.G
                                            d.SpecifiedColor.B = s.SpecifiedColor.B
                                            d.SpecifiedColor.A = s.SpecifiedColor.A
                                        end)
                                    end
                                end
                            end)
                            box:AddChild(w)
                            probeEntry = w
                            log("inject: PROBE WRAP added")
                        end)
                    end)
                end)
            end)
        end)
    end)
end)

local ticks = 0
LoopAsync(250, function()
    ticks = ticks + 1
    if ticks >= 480 then log("probe window over") return true end
    return false
end)
