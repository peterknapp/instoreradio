gl.setup(NATIVE_WIDTH, NATIVE_HEIGHT)
local text = "Hallo Welt"

util.json_watch("config.json", function(config)
    text = config.text
end)

function node.render()
    gl.clear(0,0,0,1)
    font:write(100, 100, text, 64, 1,1,1,1)
end
