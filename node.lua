gl.setup(NATIVE_WIDTH, NATIVE_HEIGHT)

local font = nil
local font_load_error = nil
do
    local ok, loaded_or_err = pcall(resource.load_font, "font.ttf")
    if ok then
        font = loaded_or_err
    else
        font_load_error = tostring(loaded_or_err)
    end
end

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
local hint = "Hint: If no sound, check device setting 'Audio enabled'."

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

local function handle_stream_command(arg)
    if arg == "start" then
        start_stream()
    elseif arg == "stop" then
        stop_stream()
    elseif arg == "refresh_meta" then
        write_refresh_request()
    end
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

util.data_mapper{
    ["stream"] = handle_stream_command;
}

-- Fallback parser for legacy/raw commands.
node.event("data", function(data)
    local cmd, arg = data:match("^([^:]+):(.+)$")
    if cmd == "stream" then
        handle_stream_command(arg)
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
    gl.clear(0.08, 0.08, 0.1, 1)

    -- Always draw a visible status stripe, even if font loading fails.
    if stream_state == "loaded" then
        gl.rect(0.2, 0.75, 0.2, 1, 40, 40, WIDTH - 40, 90)
    elseif stream_state == "loading" then
        gl.rect(0.95, 0.75, 0.2, 1, 40, 40, WIDTH - 40, 90)
    else
        gl.rect(0.85, 0.2, 0.2, 1, 40, 40, WIDTH - 40, 90)
    end

    if not font then
        -- Font unavailable: keep rendering the bars so we still know code runs.
        if stream_error == "" and font_load_error then
            stream_error = "Font load failed"
        end
        return
    end

    font:write(80, 70, config.text, 56, 1, 1, 1, 1)
    font:write(80, 130, config.dummy_text, 36, 0.7, 0.9, 1, 1)

    font:write(80, 205, "State: " .. stream_state, 44, 0.9, 0.9, 0.9, 1)
    if stream_error ~= "" then
        font:write(80, 255, "Error: " .. stream_error, 30, 1, 0.4, 0.4, 1)
    end
    if font_load_error then
        font:write(80, 285, "Font warning: " .. font_load_error, 22, 1, 0.6, 0.3, 1)
    end

    font:write(80, 305, hint, 24, 1, 0.9, 0.4, 1)

    font:write(80, 355, "Stream metadata", 32, 1, 1, 0.5, 1)
    font:write(80, 395, "Title: " .. meta_title, 28, 1, 1, 1, 1)
    font:write(80, 430, "Updated: " .. meta_updated, 24, 0.8, 0.8, 0.8, 1)
end
