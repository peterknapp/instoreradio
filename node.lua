gl.setup(NATIVE_WIDTH, NATIVE_HEIGHT)

function node.render()
    gl.clear(0.15, 0.35, 0.85, 1)
    gl.rect(1, 1, 1, 1, 60, 60, WIDTH - 60, 140)
end
