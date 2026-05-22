gl.setup(NATIVE_WIDTH, NATIVE_HEIGHT)
local font = resource.load_font "font.ttf"
local text = "Hallo die ganze Welt"
local build_marker = "Build 2026-05-22-1948"

util.json_watch("config.json", function(config)
    text = config.text
end)

function node.render()
    gl.clear(0,0,0,1)
    font:write(100, 100, text, 64, 1,1,1,1)
    font:write(100, 180, build_marker, 32, 1,1,0,1)
end
