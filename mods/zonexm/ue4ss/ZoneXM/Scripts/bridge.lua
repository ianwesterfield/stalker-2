local Bridge = {}

local DIRECTORY = assert(os.getenv("USERPROFILE"), "ZoneXM requires USERPROFILE") .. "\\ZoneXM"
local MEDIA_PATH = DIRECTORY .. "\\now-playing.txt"
local NOTIFICATION_PATH = DIRECTORY .. "\\notification.txt"
local STALE_SECONDS = 8

Bridge.ALERT_PATH = DIRECTORY .. "\\alert.flag"
Bridge.STYLE_PATH = DIRECTORY .. "\\subtitle-style.txt"

---@class ZoneXMBannerEvent
---@field age? number
---@field artist string Artist for media; body text for notifications.
---@field key string
---@field notification? boolean
---@field source? string
---@field title string

---@param path string
---@return string?
function Bridge.readSnapshot(path)
    local file, openError, errorCode = io.open(path, "rb")

    if not file then
        if errorCode == 2 then
            return nil
        end

        error("cannot read banner snapshot: " .. tostring(openError))
    end

    local data, readError = file:read(4097)
    local closed, closeError = file:close()
    assert(data, "cannot read banner snapshot: " .. tostring(readError))
    assert(closed, "cannot close banner snapshot: " .. tostring(closeError))
    assert(#data > 0, "empty banner snapshot")
    assert(#data <= 4096, "banner snapshot exceeds 4096 bytes")
    assert(utf8.len(data), "banner snapshot is not UTF-8")
    assert(not data:find("[%z\1-\9\11-\31\127]"), "invalid banner control characters")

    return data
end

---@param now number Unix time in seconds.
---@return ZoneXMBannerEvent?
function Bridge.readTrack(now)
    local data = Bridge.readSnapshot(MEDIA_PATH)

    if not data then
        return nil
    end

    local timestamp, source, title, artist = data:match("^ZoneXM/1\n(%d+)\n([^\n]*)\n([^\n]*)\n([^\n]*)\n$")
    assert(timestamp, "invalid now-playing snapshot")

    local age = now - tonumber(timestamp)

    if age < -2 or age > STALE_SECONDS or source == "" or title == "" then
        return nil
    end

    return { artist = artist, key = source .. "\n" .. title .. "\n" .. artist, title = title }
end

---@param now number Unix time in seconds.
---@return ZoneXMBannerEvent? event
---@return boolean companionActive
---@return string? expiredKey
---@return number? expiredAge
function Bridge.readNotification(now)
    local data = Bridge.readSnapshot(NOTIFICATION_PATH)

    if not data then
        return nil, false
    end

    local heartbeat, received, source, eventId, _, title, body = data:match(
        "^ZoneXM/notification/1\n(%d+)\n(%d+)\n([^\n]*)\n([^\n]*)\n([^\n]*)\n([^\n]*)\n([^\n]*)\n$"
    )

    assert(heartbeat, "invalid notification snapshot")

    local heartbeatAge = now - tonumber(heartbeat)

    if heartbeatAge < -2 or heartbeatAge > STALE_SECONDS then
        return nil, false
    end

    -- A live companion owns banners, even while idle, to avoid duplicate media announcements.
    if source == "" or eventId == "" or title == "" then
        return nil, true
    end

    local age = now - tonumber(received)
    local key = source .. "\n" .. eventId

    if age < -2 or age >= 30 then
        return nil, true, key, age
    end

    return {
        age = age,
        artist = body,
        key = key,
        notification = true,
        source = source,
        title = title,
    },
        true
end

function Bridge.writeAlert()
    -- The companion creates the directory; shelling out here steals game input focus.
    local file, openError = io.open(Bridge.ALERT_PATH, "w")

    assert(file, "cannot write alert flag; start ZoneXM Companion: " .. tostring(openError))

    local written, writeError = file:write(tostring(os.time()))
    local closed, closeError = file:close()

    assert(written, "cannot write alert flag: " .. tostring(writeError))
    assert(closed, "cannot close alert flag: " .. tostring(closeError))
end

function Bridge.clearAlert()
    local removed, removeError, errorCode = os.remove(Bridge.ALERT_PATH)
    assert(removed or errorCode == 2, "cannot remove alert flag: " .. tostring(removeError))
end

return Bridge
