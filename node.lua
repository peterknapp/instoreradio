gl.setup(NATIVE_WIDTH, NATIVE_HEIGHT)

local font = resource.load_font "font.ttf"

local has_audio_api = sys.audio and sys.audio.loudness and sys.audio.freq
local has_audio_provides = sys.provides "audio"


util.no_globals()

local json = require "json"
local deque = require "deque"

local w = resource.create_colored_texture(1,1,1,1)
local base_volume = 1

local function _safe_json_encode(v)
    local ok, enc = pcall(json.encode, v)
    if ok then
        return enc
    end
    return '{"encode_error":true}'
end

local playback_events = {}
local playback_max_events = 400

local function persist_playback_events()
    -- File based logging is handled by service via `logread`.
    -- Keep this as a no-op in Lua to avoid filesystem/io restrictions.
end

local function log_playback(event, details)
    local entry = {
        ts = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        event = event,
        details = details or {},
    }
    playback_events[#playback_events+1] = entry
    while #playback_events > playback_max_events do
        table.remove(playback_events, 1)
    end
    print("[PLAYBACK] " .. event .. " " .. _safe_json_encode(details or {}))
    persist_playback_events()
end


local function log(fmt, ...)
    print(string.format("[PLAYER] "..fmt, ...))
end

local function dbg_writer()
    local y = 5
    local x = 5

    local function write(fmt, ...)
        font:write(x, y, string.format(fmt, ...), 32, 1,1,1,1)
        y = y + 32
    end

    local function space()
        y = y + 10
    end

    local function reset()
        y = 0
    end

    return {
        write = write;
        space = space;
        reset = reset;
    }
end

local dbg = dbg_writer()

-------------------------------------------------------------------------------------

local function StreamPlayer(url, buffer)
    local stream
    local handle
    local volume = 0
    local volume_target = 0
    local healthy = false
    local last_error = ""
    local next_open = sys.now()
    local worked_once = false
    local startup_grace_until = 0
    local last_preload = nil
    local last_preload_change = sys.now()
    local paused_since = nil

    local function is_ready()
        local s, preload = stream:state()
        if s == "loaded" or s == "paused" then
            local ready_threshold = math.max(5, buffer - 3)
            return preload >= ready_threshold
        else
            return false
        end
    end

    local function is_failing()
        local s, preload = stream:state()
        if s == "loaded" or s == "paused" then
            return preload < 5
        else
            return true
        end
    end

    local function is_gone()
        local s = stream:state()
        return s == "finished" or s == "error"
    end

    local function terminate()
        if stream then
            stream:dispose()
            stream = nil
        end
    end

    local function handle_stream()
        local started = sys.now()
        log("starting stream")
        while not is_ready() do
            if sys.now() > started + buffer + 25 then
                log("cannot open stream")
                -- try again
                return terminate()
            end
            coroutine.yield()
        end

        stream:start()

        log("starting stream %s", url)
        log_playback("stream_started", {url=url})
        healthy = true
        worked_once = true

        while not is_failing() and not is_gone() do
            coroutine.yield()
        end

        log("ending stream %s", url)
        log_playback("stream_ended", {url=url})
        healthy = false

        while volume > 0 and not is_gone() do
            coroutine.yield()
        end

        return terminate()
    end

    local function open()
        if url == "" then
            last_error = "No stream configured"
            log_playback("stream_open_failed", {reason="no_stream_configured"})
            next_open = sys.now() + 5
            return
        end
        local ok, next_stream = pcall(resource.load_audio, {
            file = url,
            buffer = buffer + 5,
            paused = true,
        })
        if not ok then
            last_error = next_stream
            log_playback("stream_open_failed", {reason="load_audio_error", error=tostring(next_stream), url=url})
            next_open = sys.now() + 5
            return
        end
        stream = next_stream
        log_playback("stream_opened", {url=url, buffer=buffer})
        startup_grace_until = sys.now() + math.max(20, math.min(buffer + 20, 120))
        last_preload = nil
        last_preload_change = sys.now()
        paused_since = nil
        volume = 0
        volume_target = 0
        stream:volume(volume * base_volume)
        handle = coroutine.wrap(handle_stream)
    end

    local function debug()
        dbg.write("Stream")
        if not stream then
            dbg.write(" last error: %s", last_error)
            dbg.write(" next open: %f", next_open - sys.now())
            dbg.space()
        else
            local s, preload = stream:state()
            dbg.write(" url: %s", url)
            dbg.write(" state: %s", s)
            if s == "error" then
                dbg.write(" error: %s", preload)
            else
                dbg.write(" cur buffer: %s", preload or 0)
            end
            dbg.write(" target buffer: %ds", buffer)
            dbg.write(" volume: %f", volume)
            for k, v in pairs(stream:metadata()) do
                dbg.write("  %s: %s", k, v)
            end
        end
        dbg.space()
    end

    local function tick()
        if not stream and sys.now() > next_open then
            open()
        end
        debug()
        if not stream then
            return
        end
        local state, preload = stream:state()
        local preload_num = tonumber(preload)
        if preload_num and preload_num ~= last_preload then
            last_preload = preload_num
            last_preload_change = sys.now()
        end
        if (state == "paused" or state == "loaded") and not in_startup_grace() and volume_target > 0 then
            if not paused_since then
                paused_since = sys.now()
            end
        else
            paused_since = nil
        end
        if volume < volume_target then
            volume = math.min(1, volume + 0.02)
        elseif volume > volume_target then
            volume = math.max(0, volume - 0.02)
        end
        stream:volume(volume * base_volume)
        handle()
    end

    local function set_volume(vol)
        volume_target = vol
    end

    local function on()
        set_volume(1)
    end

    local function off()
        set_volume(0)
    end

    local function is_healthy()
        return healthy
    end

    local function has_worked_once()
        return worked_once
    end

    local function in_startup_grace()
        return sys.now() < startup_grace_until
    end

    local function inspect()
        if not stream then
            return {
                has_stream = false,
                healthy = healthy,
                worked_once = worked_once,
                startup_grace = in_startup_grace(),
                last_error = last_error,
            }
        end
        local s, preload = stream:state()
        local paused_for = paused_since and (sys.now() - paused_since) or 0
        local no_preload_progress_for = sys.now() - last_preload_change
        local runtime_broken = (
            (s == "paused" or s == "loaded") and
            not in_startup_grace() and
            worked_once and
            paused_for > 25 and
            no_preload_progress_for > 25
        )
        return {
            has_stream = true,
            state = s,
            preload = preload,
            target_buffer = buffer,
            healthy = healthy,
            worked_once = worked_once,
            startup_grace = in_startup_grace(),
            last_error = last_error,
            paused_for = paused_for,
            no_preload_progress_for = no_preload_progress_for,
            runtime_broken = runtime_broken,
        }
    end

    return {
        tick = tick;
        on = on;
        off = off;
        set_volume = set_volume;
        is_healthy = is_healthy;
        has_worked_once = has_worked_once;
        in_startup_grace = in_startup_grace;
        inspect = inspect;
        terminate = terminate;
    }
end

local function LocalPlayer(source, initial_volume)
    local volume = initial_volume or 1
    local volume_target = initial_volume or 1

    local audio = resource.load_audio{
        file = source.file:copy(),
        buffer = 2,
        paused = true,
    }

    local function eos()
        local s = audio:state()
        return s == "finished" or s == "error"
    end

    local function terminate()
        audio:dispose()
        audio = nil
    end

    local function debug()
        local s, preload = audio:state()
        dbg.write("Local")
        dbg.write(" file: %s", source.name)
        dbg.write(" state: %s", s)
        dbg.write(" cur buffer: %.3fs", preload or 0)
        dbg.write(" volume: %f", volume)
        dbg.space()
    end

    local function tick()
        if volume < volume_target then
            volume = math.min(1, volume + 0.02)
        elseif volume > volume_target then
            volume = math.max(0, volume - 0.02)
        end
        if volume > 0 then
            audio:start()
        else
            audio:stop()
        end
        audio:volume(volume * base_volume)

        debug()
    end

    local function set_volume(vol)
        volume_target = vol
    end

    local function on()
        set_volume(1)
    end

    local function off()
        set_volume(0)
    end

    return {
        tick = tick;
        on = on;
        off = off;
        set_volume = set_volume;
        eos = eos;
        terminate = terminate;
    }
end

-------------------------------------------------------------------------------------

local CreateStream = (function()
    local stream
    local last_url
    local last_buffer

    return function(new_url, new_buffer)
        if new_url == last_url and new_buffer == last_buffer then
            return stream
        end
        log("setting new stream url %s", new_url)
        last_url = new_url
        last_buffer = new_buffer
        if stream then
            stream.terminate()
        end
        stream = StreamPlayer(new_url, new_buffer)
        return stream
    end
end)()

local function Fallback()
    local pos = 0
    local playlist = {}
    local force_fallback_until = sys.now()
    local min_fallback = 60
    local unstable_since = nil
    local unstable_confirm_seconds = 8
    local player

    local function set_playlist(items)
        local next_playlist = {}
        for idx, item in ipairs(items) do
            next_playlist[idx] = {
                file = resource.open_file(item.file.asset_name);
                name = item.file.filename;
            }
        end

        -- make switching atomic. In case the above loop
        -- fails for any reason, nothing will change.
        playlist = next_playlist
        pos = 0
    end

    local function set_min_fallback(seconds)
        seconds = tonumber(seconds) or 60
        if seconds < 30 then
            seconds = 30
        end
        min_fallback = seconds
    end

    local function get_next()
        pos = pos % #playlist + 1
        local item = playlist[pos]
        if not item then
            return {
                file = resource.open_file "idle.mp3",
                name = "idle.mp3",
            }
        else
            return {
                file = item.file,
                name = item.name,
            }
        end
    end

    local function load_next()
        if player then
            player.terminate()
        end
        player = LocalPlayer(get_next())
    end

    local function is_active()
        return sys.now() < force_fallback_until
    end

    local function activate(for_seconds)
        for_seconds = tonumber(for_seconds) or 0
        if for_seconds <= 0 then
            force_fallback_until = sys.now()
            unstable_since = nil
            return
        end
        log("triggering fallback for %d seconds", for_seconds)
        log_playback("fallback_activated", {seconds=for_seconds})
        force_fallback_until = sys.now() + for_seconds
    end

    local function check_if_needed(stream, silence_detector)
        local state_details = stream.inspect()
        local broken = (not stream.is_healthy()) or state_details.runtime_broken

        -- Already in fallback? Keep it active as long as stream is still broken.
        if is_active() then
            if broken then
                force_fallback_until = math.max(force_fallback_until, sys.now() + 5)
            end
            unstable_since = nil
            return
        end

        -- Stream startup grace should only suppress fallback during initial
        -- startup. Once the stream has already worked before, don't let repeated
        -- reconnect attempts mask a prolonged outage.
        if stream.in_startup_grace()
           and not stream.has_worked_once()
           and state_details.has_stream
           and (state_details.state == "loaded" or state_details.state == "paused")
        then
            unstable_since = nil
            return
        end

        if broken and (not state_details.runtime_broken) and state_details.has_stream and (state_details.state == "paused" or state_details.state == "loaded") then
            local preload = tonumber(state_details.preload) or 0
            local target = tonumber(state_details.target_buffer) or 0
            local startup_like_threshold = math.max(10, target - 5)
            if preload >= startup_like_threshold then
                -- Stream already buffered and waiting to start/resume: do not
                -- classify this as broken.
                broken = false
            end
        end
        local silent = silence_detector.is_silent()
        local silence_dur = silence_detector.silence_duration()
        local silence_thr = silence_detector.threshold()
        -- For healthy streams, require additional silence time to avoid
        -- false positives on quiet intros/passages.
        local silent_hard = silence_dur > (silence_thr + 20)
        local trigger_silent = broken and silent or ((not broken) and silent_hard)

        -- Stream healthy and not silent -> clear pending failure.
        if not broken and not trigger_silent then
            unstable_since = nil
            return
        end

        -- Require a short confirmation window before activating fallback.
        -- This filters short transient jitter/dips without removing
        -- the fallback safety mechanism.
        if not unstable_since then
            unstable_since = sys.now()
            return
        end

        if sys.now() - unstable_since >= unstable_confirm_seconds then
            local details = state_details
            details.reason_broken = broken
            details.reason_runtime_broken = state_details.runtime_broken and true or false
            details.reason_silent_soft = silent
            details.reason_silent_hard = silent_hard
            details.reason_silent = trigger_silent and not broken
            details.silence_duration = silence_dur
            details.silence_threshold = silence_thr
            log_playback("fallback_check_triggered", details)
            activate(min_fallback)
            unstable_since = nil
        end
    end

    local function tick()
        if not player or player.eos() then
            load_next()
        end
        dbg.write("Fallback")
        if is_active() then
            dbg.write(" active for %.3f", force_fallback_until - sys.now())
        else
            dbg.write(" not active")
            if unstable_since then
                dbg.write(" pending for %.3fs", sys.now() - unstable_since)
            end
        end
        dbg.space()
        player.tick()
    end

    return {
        tick = tick;
        check_if_needed = check_if_needed;
        activate = activate;
        set_playlist = set_playlist;
        set_min_fallback = set_min_fallback;
        is_active = is_active;
        set_volume = function(...) player.set_volume(...) end;
        on = function() player.on() end;
        off = function() player.off() end;
    }
end


local function AdBlockScheduler()
    local queue = deque:new()
    local player = nil
    local volume = 0
    local clock_h, clock_m
    local last_trigger_h, last_trigger_m
    local ad_blocks = {}
    local block_cursor = {}
    local current_item = nil
    local current_started_at = 0

    local function normalize_block_name(name)
        name = tostring(name or "")
        if name == "" or name == "Werbeblock" then
            return "Ad Block"
        end
        return name
    end

    local function minute_match(m, minute_config)
        if m == minute_config then
            return true
        elseif minute_config == "every-3" then
            return m % 3 == 0
        elseif minute_config == "every-5" then
            return m % 5 == 0
        elseif minute_config == "every-10" then
            return m % 10 == 0
        elseif minute_config == "every-15" then
            return m % 15 == 0
        elseif minute_config == "every-20" then
            return m % 20 == 0
        end
        return false
    end

    local function set_blocks(new_ad_blocks)
        local blocks = {}
        for idx, block in ipairs(new_ad_blocks or {}) do
            local files = {}
            for _, media in ipairs(block.files or {}) do
                files[#files+1] = {
                    file = resource.open_file(media.file.asset_name),
                    name = media.file.filename,
                }
            end
            blocks[#blocks+1] = {
                name = normalize_block_name(block.name or ("Ad Block "..idx)),
                start_hour = tonumber(block.start_hour) or 0,
                end_hour = tonumber(block.end_hour) or 23,
                minute = block.minute,
                mode = tostring(block.mode or "all"),
                duck_volume = tonumber(block.duck_volume) or 0,
                files = files,
            }
        end
        ad_blocks = blocks
    end

    local function enqueue(item)
        log("enqueue new item: %s", item.file.name)
        queue:push_right(item)
    end

    local function stop()
        if current_item then
            local played_for = math.max(0, sys.now() - current_started_at)
            log_playback("ad_block_item_finished", {
                block = normalize_block_name(current_item.block_name or "Ad Block"),
                file = current_item.file.name,
                played_seconds = played_for,
            })
            current_item = nil
            current_started_at = 0
        end
        player.terminate()
        player = nil
    end

    local function abort()
        if player then
            stop()
        end
        queue = deque:new()
    end

    local function update_time(h, m, allow_trigger)
        clock_h = h
        clock_m = m

        if not allow_trigger then
            return
        end

        if h == last_trigger_h and m == last_trigger_m then
            return
        end
        last_trigger_h = h
        last_trigger_m = m

        for _, block in ipairs(ad_blocks) do
            if block.minute ~= "never" and
               h >= block.start_hour and
               h <= block.end_hour and
               minute_match(m, block.minute)
            then
                local count = #block.files
                if count > 0 then
                    local queued_items = {}
                    if block.mode == "single" then
                        local next_idx = (block_cursor[block.name] or 0) % count + 1
                        block_cursor[block.name] = next_idx
                        queued_items[1] = {
                            file = block.files[next_idx],
                            volume = block.duck_volume,
                            block_name = block.name,
                            block_item_index = next_idx,
                            block_item_count = count,
                        }
                    else
                        for i, file in ipairs(block.files) do
                            queued_items[#queued_items+1] = {
                                file = file,
                                volume = block.duck_volume,
                                block_name = block.name,
                                block_item_index = i,
                                block_item_count = count,
                            }
                        end
                    end

                    log_playback("ad_block_triggered", {
                        block = normalize_block_name(block.name),
                        mode = block.mode,
                        scheduled = string.format("%02d:%02d", h, m),
                        items = #queued_items,
                        total_media = count,
                    })
                    for _, item in ipairs(queued_items) do
                        enqueue(item)
                    end
                end
            end
        end
    end

    local function debug()
        dbg.write("Ad Blocks")
        if clock_h then
            dbg.write(" time: %02d:%02d", clock_h, clock_m)
        else
            dbg.write(" time: <unknown>")
        end
        dbg.write(" queue: %d items", queue:length())
        dbg.space()
    end

    local function tick()
        if player then
            player.tick()
            if player.eos() then
                stop()
            end
        elseif not queue:is_empty() then
            local item = queue:pop_left()
            log("about to play next item")
            player = LocalPlayer(item.file)
            volume = item.volume
            current_item = item
            current_started_at = sys.now()
            log_playback("ad_block_item_started", {
                block = normalize_block_name(item.block_name or "Ad Block"),
                file = item.file.name,
                item_index = item.block_item_index,
                item_count = item.block_item_count,
            })
        end
        debug()
    end

    local function is_playing()
        return player ~= nil
    end

    local function get_volume()
        return volume
    end

    return {
        tick = tick;
        abort = abort;
        set_blocks = set_blocks;
        update_time = update_time;
        get_volume = get_volume;
        is_playing = is_playing;
    }
end

local function SilenceDetector()
    local above_threshold = sys.now()
    local loudness
    local threshold = 5
    local activity_floor = 0.05
    local t = {}

    local function tick()
        if not has_audio_api then
            loudness = 0
            return
        end
        loudness = sys.audio.loudness()
        if loudness > activity_floor then
            above_threshold = sys.now()
        end
    end

    local function set_threshold(new_threshold)
        threshold = new_threshold
    end

    local function set_floor(new_floor)
        activity_floor = tonumber(new_floor) or 0.05
    end

    local function silence_duration()
        return sys.now() - above_threshold
    end

    local function is_silent()
        return silence_duration() > threshold
    end

    local function debug()
        dbg.write("Silence detector")
        dbg.write(" silent for: %f", silence_duration())
        dbg.write(" threshold: %f", threshold)
        dbg.write(" floor: %f", activity_floor)
        dbg.write(" loudness: %f", loudness)
        dbg.space()
    end

    local function graph()
        if not has_audio_api then
            return
        end
        t = sys.audio.freq(t)
        local function avg(off, count)
            local sum = 0
            for i = off, off+count do
                sum = sum + t[i]
            end
            return sum/count
        end
        for i = 1, 32 do
            local x = i * WIDTH/33
            w:draw(x, HEIGHT-30  - t[i]*(HEIGHT-20), x + 30, HEIGHT-30, 0.3)
        end
        w:draw(0, HEIGHT-30, WIDTH*sys.audio.loudness(), HEIGHT)
    end

    return {
        tick = tick;
        is_silent = is_silent;
        set_threshold = set_threshold;
        set_floor = set_floor;
        silence_duration = silence_duration;
        threshold = function() return threshold end;
        debug = debug;
        graph = graph;
    }
end

-------------------------------------------------------------------------------------

local stream
local fallback = Fallback()
local adblock = AdBlockScheduler()
local silence_detector = SilenceDetector()
local manual_stopped = false
local suppress_fallback_until = 0
local current_stream_url = ""
local current_stream_buffer = 10
local last_local_clock_minute = -1

local function rebuild_stream()
    stream = CreateStream(current_stream_url, current_stream_buffer)
end

util.json_watch("config.json", function(config)
    base_volume = tonumber(config.base_volume) or 1
    current_stream_url = tostring(config.stream or "")
    current_stream_buffer = tonumber(config.buffer) or 20
    rebuild_stream()
    fallback.set_playlist(config.playlist)
    fallback.set_min_fallback(tonumber(config.min_fallback) or 120)
    adblock.set_blocks(config.ad_blocks)
    silence_detector.set_threshold(tonumber(config.silence_threshold) or 20)
    silence_detector.set_floor(tonumber(config.silence_floor) or 0.02)
    node.gc()
end)

util.data_mapper{
    fallback = function(force)
        if force == "yes" then
            fallback.activate(1000000000)
        else
            fallback.activate(0)
        end
    end;
    ["player/start"] = function()
        local was_stopped = manual_stopped
        manual_stopped = false
        suppress_fallback_until = sys.now() + 8
        fallback.activate(0)
        if was_stopped then
            log_playback("manual_start", {suppress_fallback_seconds=8})
        end
    end;
    ["player/stop"] = function()
        manual_stopped = true
        suppress_fallback_until = 0
        adblock.abort()
        fallback.activate(0)
        fallback.off()
        if stream then
            stream.terminate()
            rebuild_stream()
        end
        log_playback("manual_stop", {})
    end;
    time = function(msg)
        local time = json.decode(msg)
        adblock.update_time(time.hour, time.minute, false)
    end;
}


local last_source = "init"

local function set_source(next_source, reason)
    if last_source ~= next_source then
        log_playback("source_changed", {source=next_source, reason=reason or ""})
        last_source = next_source
    end
end

function node.render()
    dbg.reset()

    -- Keep ad-block scheduling independent from external root/time events.
    -- This ensures schedules still trigger even if hosted.py time mapping is missing.
    local now = os.date("*t")
    if now and now.min ~= last_local_clock_minute and now.sec <= 2 then
        last_local_clock_minute = now.min
        adblock.update_time(now.hour, now.min, true)
    end

    if not has_audio_api then
        gl.clear(0.2, 0.0, 0.0, 1)
        font:write(5, 5, "audio backend unavailable", 32, 1,1,1,1)
        font:write(5, 40, "sys.provides(audio): "..tostring(has_audio_provides), 24, 1,1,1,1)
        return
    end

    if manual_stopped then
        set_source("stopped", "manual_stop")
        gl.clear(0, 0, 0.45, 1)
        stream.off()
        fallback.off()
        adblock.abort()
        return
    end

    if sys.now() > suppress_fallback_until then
        fallback.check_if_needed(stream, silence_detector)
    end

    local l = sys.audio.loudness()

    if adblock.is_playing() then
        set_source("ad_block", "ad_block_playing")
        gl.clear(l, l, 0, 1)
    elseif fallback.is_active() then
        set_source("fallback", "fallback_active")
        gl.clear(l, 0, 0, 1)
    else
        set_source("stream", "default")
        gl.clear(0, l, 0, 1)
    end

    dbg.write("NOW PLAYING")
    if last_source == "ad_block" then
        dbg.write(" source: AD BLOCK")
    elseif last_source == "fallback" then
        dbg.write(" source: FALLBACK")
    elseif last_source == "stream" then
        dbg.write(" source: STREAM")
    elseif last_source == "stopped" then
        dbg.write(" source: STOPPED")
    else
        dbg.write(" source: %s", last_source)
    end
    dbg.space()

    stream.tick()
    fallback.tick()
    adblock.tick()
    silence_detector.tick()

    if adblock.is_playing() then
        if fallback.is_active() then
            fallback.set_volume(adblock.get_volume())
        else
            stream.set_volume(adblock.get_volume())
        end
    elseif fallback.is_active() then
        fallback.on()
        stream.off()
    else
        stream.on()
        fallback.off()
    end

    silence_detector.debug()
    silence_detector.graph()
end
