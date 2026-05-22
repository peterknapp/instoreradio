gl.setup(NATIVE_WIDTH, NATIVE_HEIGHT)

local running = false
local pulse = 0

util.data_mapper{
    stream = function(cmd)
        if cmd == "start" then
            running = true
        elseif cmd == "stop" then
            running = false
        end
    end;
}

util.set_interval(0.05, function()
    pulse = (pulse + 0.02) % 1
end)

function node.render()
    if running then
        gl.clear(0.1, 0.5 + pulse * 0.5, 0.1, 1)
    else
        gl.clear(0.5 + pulse * 0.5, 0.1, 0.1, 1)
    end

    gl.rect(1, 1, 1, 1, 40, 40, WIDTH - 40, 120)
end
