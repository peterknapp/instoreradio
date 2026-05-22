gl.setup(NATIVE_WIDTH, NATIVE_HEIGHT)

local mode = "stopped"
local stream = nil
local stream_url = ""
local autostart = true

local function set_mode(next_mode)
    mode = next_mode
end

local function stop_stream()
    if stream then
        stream:dispose()
        stream = nil
    end
    set_mode("stopped")
end

local function start_stream()
    if stream_url == "" then
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
        set_mode("error")
        return
    end

    stream = obj
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
        local s = stream:state()
        if s then
            mode = s
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
end
