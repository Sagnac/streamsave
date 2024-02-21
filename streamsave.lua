--[[

streamsave.lua
Version 0.27.3-lite
2023-02-21
https://github.com/Sagnac/streamsave/tree/lite

]]

local options = require 'mp.options'
local utils = require 'mp.utils'
local msg = require 'mp.msg'

-- default user settings
-- change these in streamsave.conf
local opts = {
    save_directory  = [[]],        -- output file directory
    dump_mode       = "ab",        -- <ab|current|continuous>
    output_label    = "increment", -- <increment|range|timestamp|overwrite>
    force_extension = "",          -- <.ext> extension will be .ext if set
    force_title     = "",          -- <title> custom title used for the filename
    range_marks     = true,        -- <yes|no> set chapters at A-B loop points?
}

local cycle_modes = {
    "ab",
    "current",
    "continuous",
}

local modes = {}
for i, v in ipairs(cycle_modes) do
    modes[v] = i
end

local mode_info = {
    continuous = "Continuous",
    ab = "A-B loop",
    current = "Current position"
}

local labels = {
    increment = true,
    range = true,
    timestamp = true,
    overwrite = true,
}

setmetatable(cycle_modes, {
    __index = function(t) return t[1] end,
    __call  = function(t) return t[modes[opts.dump_mode] + 1] end
})

-- for internal use
local file = {
    name,            -- file name (path to file)
    path,            -- directory the file is written to
    title,           -- media title
    inc,             -- filename increments
    ext,             -- file extension
    loaded,          -- flagged once the initial load has taken place
    pending,         -- number of files pending write completion (max 2)
    writing,         -- file writing object returned by the write command
}

local loop = {
    a,               -- A loop point as number type
    b,               -- B loop point as number type
    a_revert,        -- A loop point prior to keyframe alignment
    b_revert,        -- B loop point prior to keyframe alignment
    range,           -- A-B loop range
    aligned,         -- are the loop points aligned to keyframes?
    continuous,      -- is the writing continuous?
}

local update = {}       -- option update functions, {mode, label} ⊈ update
local chapter_list = {} -- initial chapter list
local ab_chapters = {}  -- A-B loop point chapters

local webm = {
    vp8 = true,
    vp9 = true,
    av1 = true,
    opus = true,
    vorbis = true,
    none = true,
}

local mp4 = {
    h264 = true,
    hevc = true,
    av1 = true,
    mp3 = true,
    flac = true,
    aac = true,
    none = true,
}

local title_change
local container
local cache_write
local get_chapters
local chapter_points

local function enabled(option)
    return string.len(option) > 0
end

local function validate_opts()
    if not modes[opts.dump_mode] then
        msg.error("Invalid dump_mode '" .. opts.dump_mode .. "'")
        opts.dump_mode = "ab"
    end
    if not labels[opts.output_label] then
        msg.error("Invalid output_label '" .. opts.output_label .. "'")
        opts.output_label = "increment"
    end
end

local function append_slash(path)
    if not path:match("[\\/]", -1) then
        return path .. "/"
    else
        return path
    end
end

function update.save_directory()
    if #opts.save_directory == 0 then
        file.path = opts.save_directory
        return
    end
    -- expand mpv meta paths (e.g. ~~/directory)
    opts.save_directory = append_slash(opts.save_directory)
    file.path = append_slash(mp.command_native{"expand-path", opts.save_directory})
end

function update.force_title()
    if enabled(opts.force_title) then
        file.title = opts.force_title
    elseif file.title then
        title_change(_, mp.get_property("media-title"))
    end
end

function update.force_extension()
    if enabled(opts.force_extension) then
        file.ext = opts.force_extension
    else
        container()
    end
end

function update.range_marks()
    if opts.range_marks then
        chapter_points()
    else
        if not get_chapters() then
            mp.set_property_native("chapter-list", chapter_list)
        end
        ab_chapters = {}
    end
end

local function update_opts(changed)
    validate_opts()
    for opt, _ in pairs(changed) do
        if update[opt] then
            update[opt]()
        end
    end
end

options.read_options(opts, "streamsave", update_opts)
update_opts{force_title = true, save_directory = true}

-- dump mode switching
local function mode_switch(value)
    if value == "cycle" then
        value = cycle_modes()
    end
    if not modes[value] then
        msg.error(("Invalid dump mode '%s'."):format(value))
        return
    end
    opts.dump_mode = value
    local mode = mode_info[value]
    print(mode, "mode" .. ".")
    mp.osd_message("Cache write mode: " .. mode)
end

-- Set the principal part of the file name using the media title
function title_change(_, media_title)
    if enabled(opts.force_title) or not media_title then
        return end
    -- Replacement of reserved file name characters on Windows
    file.title = media_title:gsub("[\\/:*?\"<>|]", ".")
end

-- Determine container for standard formats
function container()
    local audio = mp.get_property("audio-codec-name", "none")
    local video = mp.get_property("video-format", "none")
    local file_format = mp.get_property("file-format")
    if not file_format then
        file.ext = nil
        return end
    if enabled(opts.force_extension) then
        file.ext = opts.force_extension
        return end
    if webm[video] and webm[audio] then
        file.ext = ".webm"
    elseif mp4[video] and mp4[audio] then
        file.ext = ".mp4"
    else
        file.ext = ".mkv"
    end
end

local function range_flip()
    loop.a = mp.get_property_number("ab-loop-a")
    loop.b = mp.get_property_number("ab-loop-b")
    if (loop.a and loop.b) and (loop.a > loop.b) then
        loop.a, loop.b = loop.b, loop.a
        mp.set_property_number("ab-loop-a", loop.a)
        mp.set_property_number("ab-loop-b", loop.b)
    end
end

local function loop_range()
    local a_loop_osd = mp.get_property_osd("ab-loop-a")
    local b_loop_osd = mp.get_property_osd("ab-loop-b")
    loop.range = a_loop_osd .. " - " .. b_loop_osd
    return loop.range
end

local function set_name(label, title)
    title = title or file.title
    return file.path .. title .. label .. file.ext
end

local function increment_filename()
    if set_name(-(file.inc or 1)) ~= file.name then
        file.inc = 1
        file.name = set_name(-file.inc)
    end
    -- check if file exists
    while utils.file_info(file.name) do
        file.inc = file.inc + 1
        file.name = set_name(-file.inc)
    end
end

local function range_stamp(mode)
    local file_range
    if mode == "ab" then
        file_range = "-[" .. loop_range():gsub(":", ".") .. "]"
    elseif mode == "current" then
        local file_pos = mp.get_property_osd("playback-time", "0")
        file_range = "-[" .. 0 .. " - " .. file_pos:gsub(":", ".") .. "]"
    else
        -- range tag is incompatible with full dump, fallback to increments
        increment_filename()
        return
    end
    file.name = set_name(file_range)
    -- check if file exists, append increments if so
    local i = 1
    while utils.file_info(file.name) do
        i = i + 1
        file.name = set_name(file_range .. -i)
    end
end

local function write_set(mode, file_name, file_pos, quiet)
    local command = {
        _flags = {
            (not quiet or nil) and "osd-msg",
        },
        filename = file_name,
    }
    if mode == "ab" then
        command["name"] = "ab-loop-dump-cache"
    else
        command["name"] = "dump-cache"
        command["start"] = 0
        command["end"] = file_pos or "no"
    end
    return command
end

local function on_write_finish(mode, file_name)
    return function(success, _, command_error)
        command_error = command_error and msg.error(command_error)
        -- check if file is written
        if utils.file_info(file_name) then
            if success then
                print("Finished writing cache to:", file_name)
            else
                msg.warn("Possibly broken file created at: " .. file_name)
            end
        else
            msg.error("File not written.")
        end
        if loop.continuous and file.pending == 2 then
            print("Dumping cache continuously to:", file.name)
        end
        file.pending = file.pending - 1
    end
end

function cache_write(mode, quiet, chapter)
    if not (file.title and file.ext) or file.pending == 2 then
        return end
    range_flip()
    -- evaluate tagging conditions and set file name
    if opts.output_label == "increment" then
        increment_filename()
    elseif opts.output_label == "range" then
        range_stamp(mode)
    elseif opts.output_label == "timestamp" then
        file.name = set_name(os.time(), "")
    elseif opts.output_label == "overwrite" then
        file.name = set_name("")
    end
    -- dump cache according to mode
    local file_pos
    file.pending = (file.pending or 0) + 1
    loop.continuous = mode == "continuous" or mode == "ab" and loop.a and not loop.b
    if mode == "current" then
        file_pos = mp.get_property_number("playback-time", 0)
    elseif loop.continuous and file.pending == 1 then
        print("Dumping cache continuously to:", file.name)
    end
    local commands = write_set(mode, file.name, file_pos, quiet)
    local callback = on_write_finish(mode, file.name)
    file.writing = mp.command_native_async(commands, callback)
    return true
end

--[[ This command attempts to align the A-B loop points to keyframes.
Use align-cache if you want to know which range will likely be dumped.
Keep in mind this changes the A-B loop points you've set.
This is sometimes inaccurate. Calling align_cache() again will reset the points
to their initial values. ]]
local function align_cache()
    if not loop.aligned then
        range_flip()
        loop.a_revert = loop.a
        loop.b_revert = loop.b
        mp.command("ab-loop-align-cache")
        loop.aligned = true
        print("Adjusted range:", loop_range())
    else
        mp.set_property_native("ab-loop-a", loop.a_revert)
        mp.set_property_native("ab-loop-b", loop.b_revert)
        loop.aligned = false
        print("Loop points reverted to:", loop_range())
        mp.osd_message("A-B loop: " .. loop.range)
    end
end

function get_chapters()
    local current_chapters = mp.get_property_native("chapter-list", {})
    -- make sure the master list is up to date
    if not current_chapters[1] or
       not string.match(current_chapters[1]["title"], "^[AB] loop point$")
    then
        chapter_list = current_chapters
        return true
    end
    -- if a script has added chapters after A-B points are set then
    -- add those to the original chapter list
    local current_len = #current_chapters
    local ab_len = #ab_chapters
    if current_len > ab_len then
        local last = #chapter_list
        for i = ab_len + 1, current_len do
            last = last + 1
            chapter_list[last] = current_chapters[i]
        end
    end
end

-- creates chapters at A-B loop points
function chapter_points()
    if not opts.range_marks then
        return end
    local updated = get_chapters()
    ab_chapters = {}
    -- restore original chapter list if A-B points are cleared
    -- otherwise set chapters to A-B points
    range_flip()
    if not loop.a and not loop.b then
        if not updated then
            mp.set_property_native("chapter-list", chapter_list)
        end
        return
    end
    if loop.a then
        ab_chapters[1] = {
            title = "A loop point",
            time = loop.a
        }
    end
    if loop.b then
        table.insert(ab_chapters, {
            title = "B loop point",
            time = loop.b
        })
    end
    mp.set_property_native("chapter-list", ab_chapters)
end

-- stops writing the file
local function stop()
    mp.abort_async_command(file.writing or {})
end

mp.observe_property("media-title", "string", title_change)

--[[ video and audio formats observed in order to handle track changes
useful if e.g. --script-opts=ytdl_hook-all_formats=yes
or script-opts=ytdl_hook-use_manifests=yes ]]
mp.observe_property("audio-codec-name", "string", container)
mp.observe_property("video-format", "string", container)

--[[ Loading chapters can be slow especially if they're passed from
an external file, so make sure existing chapters are not overwritten
by observing A-B loop changes only after the file is loaded. ]]
local function on_file_load()
    if file.loaded then
        chapter_points()
    else
        mp.observe_property("ab-loop-a", "native", chapter_points)
        mp.observe_property("ab-loop-b", "native", chapter_points)
        file.loaded = true
    end
end
mp.register_event("file-loaded", on_file_load)

mp.register_script_message("streamsave-mode", mode_switch)

mp.add_key_binding("Alt+z", "mode-switch", function() mode_switch("cycle") end)
mp.add_key_binding("Ctrl+x", "stop-cache-write", stop)
mp.add_key_binding("Alt+x", "align-cache", align_cache)
mp.add_key_binding("Ctrl+z", "cache-write",
                   function() cache_write(opts.dump_mode)
                   end)
