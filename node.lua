gl.setup(NATIVE_WIDTH, NATIVE_HEIGHT)

local config = {
    stream_url = "",
    autostart = true,
}

local stream = nil
local state = "stopped"

local function stop_stream()
    if stream then
        stream:dispose()
        stream = nil
    end
    state = "stopped"
end

local function start_stream()
    if not config.stream_url or config.stream_url == "" then
        state = "error"
        return
    end

    if stream then
        stream:start()
        state = "loading"
        return
    end

    stream = resource.load_video{
        file = config.stream_url;
        audio = true;
        paused = false;
        looped = true;
    }
    state = "loading"
end

util.data_mapper{
    stream = function(cmd)
        if cmd == "start" then
            start_stream()
        elseif cmd == "stop" then
            stop_stream()
        end
    end;
}

util.json_watch("config.json", function(c)
    local old_url = config.stream_url
    config.stream_url = c.stream_url or config.stream_url
    config.autostart = c.autostart ~= false

    if old_url ~= config.stream_url and stream then
        stop_stream()
        start_stream()
    end
end)

util.set_interval(0.5, function()
    if stream then
        local s = stream:state()
        if s then
            state = s
        end
    elseif config.autostart then
        start_stream()
    end
end)

function node.render()
    if state == "loaded" then
        gl.clear(0.1, 0.6, 0.15, 1)
    elseif state == "loading" then
        gl.clear(0.85, 0.55, 0.1, 1)
    elseif state == "error" then
        gl.clear(0.75, 0.1, 0.1, 1)
    else
        gl.clear(0.45, 0.15, 0.15, 1)
    end

    gl.rect(1, 1, 1, 1, 40, 40, WIDTH - 40, 120)
end
