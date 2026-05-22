gl.setup(NATIVE_WIDTH, NATIVE_HEIGHT)

local font = resource.load_font "font.ttf"
local text = "Willkommen bei Instore Radio"
local subtitle = "Dummy Text"

util.json_watch("config.json", function(config)
    text = config.text or text
    subtitle = config.dummy_text or subtitle
end)

function node.render()
    gl.clear(0, 0, 0, 1)
    font:write(100, 100, text, 64, 1, 1, 1, 1)
    font:write(100, 180, subtitle, 44, 0.7, 0.9, 1, 1)
end
