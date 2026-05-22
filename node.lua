gl.setup(NATIVE_WIDTH, NATIVE_HEIGHT)

local mode = "stopped"
local stream = nil
local stream_url = ""
local autostart = true
local last_error = ""
local error_code = 0
local font = nil
do
    local ok, f = pcall(resource.load_font, "font.ttf")
    if ok then
        font = f
    end
end

local function set_mode(next_mode)
    mode = next_mode
end

local function stop_stream()
    if stream then
        stream:dispose()
        stream = nil
    end
    last_error = ""
    error_code = 0
    set_mode("stopped")
end

local function start_stream()
    if stream_url == "" then
        last_error = "stream_url is empty"
        error_code = 1
        set_mode("error")
        return
    end

    if stream then
        stream:start()
        set_mode("loading")
        return
    end

    local ok, obj = pcall(resource.load_video, {
        file = stream_url;
        audio = true;
        paused = false;
        looped = true;
    })

    if not ok or not obj then
        last_error = ok and "load_video returned nil" or tostring(obj)
        error_code = 2
        set_mode("error")
        return
    end

    stream = obj
    last_error = ""
    error_code = 0
    set_mode("loading")
end

util.data_mapper{
    stream = function(cmd)
        if cmd == "start" then
            start_stream()
        elseif cmd == "stop" then
            stop_stream()
        elseif cmd == "refresh_meta" then
            -- no-op in this reduced test stage
        end
    end;
}

util.json_watch("config.json", function(c)
    local old_url = stream_url
    stream_url = c.stream_url or ""
    autostart = c.autostart ~= false

    if old_url ~= stream_url and stream then
        stop_stream()
        start_stream()
    end
end)

util.set_interval(0.5, function()
    if stream then
        local s, a = stream:state()
        if s then
            mode = s
        end
        if s == "error" then
            last_error = tostring(a or "unknown stream error")
            error_code = 3
        end
    elseif autostart then
        start_stream()
    end
end)

function node.render()
    if mode == "stopped" then
        gl.clear(0.15, 0.35, 0.85, 1) -- blue
    elseif mode == "loading" then
        gl.clear(0.9, 0.55, 0.1, 1) -- orange
    elseif mode == "loaded" then
        gl.clear(0.1, 0.65, 0.2, 1) -- green
    else
        gl.clear(0.8, 0.1, 0.1, 1) -- red/error
    end

    gl.rect(1, 1, 1, 1, 60, 60, WIDTH - 60, 140)

    -- Error indicator bar (font-independent):
    -- purple=1(empty url), yellow=2(load_video failed), white=3(stream runtime error), black=0(no error)
    if error_code == 1 then
        gl.rect(0.8, 0.2, 0.9, 1, 60, 160, WIDTH - 60, 210)
    elseif error_code == 2 then
        gl.rect(1.0, 0.95, 0.2, 1, 60, 160, WIDTH - 60, 210)
    elseif error_code == 3 then
        gl.rect(1, 1, 1, 1, 60, 160, WIDTH - 60, 210)
    else
        gl.rect(0, 0, 0, 1, 60, 160, WIDTH - 60, 210)
    end

    if font then
        font:write(80, 180, "mode: " .. mode, 34, 1, 1, 1, 1)
        if last_error ~= "" then
            font:write(80, 225, "error: " .. last_error, 26, 1, 0.85, 0.3, 1)
        end
    end
end
