gl.setup(NATIVE_WIDTH, NATIVE_HEIGHT)

local font = resource.load_font "font.ttf"

local config = {
    stream_url = "",
    autostart = true,
    text = "Instore Radio",
    dummy_text = "Bereit",
}

local stream = nil
local stream_state = "stopped"
local stream_error = ""
local meta_title = "-"
local meta_updated = "-"

local function write_refresh_request()
    local f = io.open("refresh.request", "w")
    if not f then
        return
    end
    f:write(tostring(sys.now()))
    f:close()
end

local function stop_stream()
    if stream then
        stream:dispose()
        stream = nil
    end
    stream_state = "stopped"
    stream_error = ""
end

local function start_stream()
    if not config.stream_url or config.stream_url == "" then
        stream_state = "error"
        stream_error = "Stream URL is empty"
        return
    end

    if stream then
        stream:start()
        stream_state = "loading"
        stream_error = ""
        return
    end

    stream = resource.load_video{
        file = config.stream_url;
        audio = true;
        paused = false;
        looped = true;
    }
    stream_state = "loading"
    stream_error = ""
end

local function reload_stream_if_running(old_url)
    if old_url == config.stream_url then
        return
    end
    local was_running = stream ~= nil
    stop_stream()
    if was_running or config.autostart then
        start_stream()
    end
end

util.json_watch("config.json", function(next_config)
    local old_url = config.stream_url
    config.stream_url = next_config.stream_url or config.stream_url
    config.autostart = next_config.autostart ~= false
    config.text = next_config.text or config.text
    config.dummy_text = next_config.dummy_text or config.dummy_text

    reload_stream_if_running(old_url)
end)

util.json_watch("stream_meta.json", function(meta)
    if not meta then
        return
    end
    meta_title = meta.title or "-"
    meta_updated = meta.updated_at or "-"
end)

node.event("data", function(data)
    local cmd, arg = data:match("^([^:]+):(.+)$")
    if not cmd then
        cmd, arg = data:match("^(%S+)%s+(.+)$")
    end
    if not cmd then
        return
    end

    if cmd == "stream" then
        if arg == "start" then
            start_stream()
        elseif arg == "stop" then
            stop_stream()
        elseif arg == "refresh_meta" then
            write_refresh_request()
        end
    end
end)

util.set_interval(1, function()
    if not stream then
        return
    end

    local state, a = stream:state()
    stream_state = state or stream_state
    if state == "error" then
        stream_error = a or "unknown error"
    end
end)

util.set_interval(0.2, function()
    if config.autostart and not stream then
        start_stream()
    end
end)

function node.render()
    gl.clear(0, 0, 0, 1)

    font:write(100, 90, config.text, 64, 1, 1, 1, 1)
    font:write(100, 160, config.dummy_text, 44, 0.7, 0.9, 1, 1)

    font:write(100, 240, "State: " .. stream_state, 36, 0.9, 0.9, 0.9, 1)
    if stream_error ~= "" then
        font:write(100, 285, "Error: " .. stream_error, 30, 1, 0.4, 0.4, 1)
    end

    font:write(100, 350, "Stream metadata", 34, 1, 1, 0.5, 1)
    font:write(100, 390, "Title: " .. meta_title, 30, 1, 1, 1, 1)
    font:write(100, 430, "Updated: " .. meta_updated, 26, 0.8, 0.8, 0.8, 1)
end
