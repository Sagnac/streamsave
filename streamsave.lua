--[[ 

streamsave.lua
Version 0.17.0
2022-5-23
https://github.com/Sagnac/streamsave

mpv script aimed at saving live streams and clipping online videos without encoding.

Essentially a wrapper around mpv's cache dumping commands, the script adds the following functionality:

* Automatic determination of the output file name and format
* Option to specify the preferred output directory
* Switch between 3 different dump modes (clip mode, full/continuous dump, write from beginning to current position)
* Prevention of file overwrites
* Acceptance of inverted loop ranges, allowing the end point to be set first
* Dynamic chapter indicators on the OSC displaying the clipping interval
* Automated stream saving

By default the A-B loop points (set using the `l` key in mpv) determine the portion of the cache written to disk.

It is advisable that you set --demuxer-max-bytes and --demuxer-max-back-bytes to larger values
(e.g. at least 1GiB) in order to have a larger cache.
If you want to use with local files set cache=yes in mpv.conf

Options are specified in ~~/script-opts/streamsave.conf

Runtime changes to all user options are supported via the `script-opts` property by using mpv's `set` or
`change-list` input commands and the `streamsave-` prefix.

save_directory sets the output file directory. Don't use quote marks or a trailing slash when specifying paths here.
Example: save_directory=C:\User Directory
mpv double tilde paths ~~/ and home path shortcuts ~/ are also accepted.
By default files are dumped in the current directory.

dump_mode=continuous will use dump-cache, setting the initial timestamp to 0 and leaving the end timestamp unset.

Use this mode if you want to dump the entire cache.
This process will continue as packets are read and until the streams change, the player is closed,
or the user presses the stop keybind.

Under this mode pressing the cache-write keybind again will stop writing the first file and
initiate another file starting at 0 and continuing as the cache increases.

If you want continuous dumping with a different starting point use the default A-B mode instead
and only set the first loop point then press the cache-write keybind.

dump_mode=current will dump the cache from timestamp 0 to the current playback position in the file.

The output_label option allows you to choose how the output filename is tagged.
The default uses iterated step increments for every file output; i.e. file-1.mkv, file-2.mkv, etc.

There are 3 other choices:
output_label=timestamp will append Unix timestamps to the file name.
output_label=range will tag the file with the A-B loop range instead using the format HH.MM.SS
e.g. file-[00.15.00 - 00.20.00].mkv
output_label=overwrite will not tag the file and will overwrite any existing files with the same name.

The force_extension option allows you to force a preferred format and sidestep the automatic detection.
If using this option it is recommended that a highly flexible container is used (e.g. Matroska).
The format is specified as the extension including the dot (e.g. force_extension=.mkv).
If this option is set, `script-message streamsave-extension revert` will run the automatic determination at runtime;
running this command again will reset the extension to what's specified in force_extension.

The force_title option will set the title used for the filename. By default the script uses the media-title.
This is specified without double quote marks in streamsave.conf, e.g. force_title=Example Title
The output_label is still used here and file overwrites are prevented if desired.
Changing the filename title to the media-title is still possible at runtime by using the revert argument,
as in the force_extension example.

The range_marks option allows the script to set temporary chapters at A-B loop points.
If chapters already exist they are stored and cleared whenever any A-B points are set.
Once the A-B points are cleared the original chapters are restored.
Any chapters added after A-B mode is entered are added to the initial chapter list.
This option is disabled by default. Set range_marks=yes in streamsave.conf in order to enable it.

The autostart and autoend options are used for automated stream capturing.
Set autostart=yes if you want the script to trigger cache writing immediately on stream load.
Set autoend to a time format of the form HH:MM:SS (e.g. autoend=01:20:08) if you want the file writing
to stop at that time.

mpv's script-message command can be used at runtime to set the dump mode, override the output title
or file extension, change the save directory, or switch the output label.
If you override the title, the file extension, or the directory, the revert argument can be used
to set it back to the default value.

Examples:
script-message streamsave-mode continuous
script-message streamsave-title "Example Title"
script-message streamsave-extension .mkv
script-message streamsave-extension revert
script-message streamsave-path ~/streams
script-message streamsave-label range

 ]]

local options = require 'mp.options'
local utils = require 'mp.utils'
local msg = require 'mp.msg'

-- default user options
-- change these in streamsave.conf
local opts = {
    save_directory = [[.]],         -- output file directory
    dump_mode = "ab",               -- <ab|current|continuous>
    output_label = "increment",     -- <increment|range|timestamp|overwrite>
    force_extension = "no",         -- <no|.ext> extension will be .ext if set
    force_title = "no",             -- <no|title> custom title used for the filename
    range_marks = false,            -- <yes|no> set chapters at A-B loop points?
    autostart = false,              -- <yes|no> automatically dump cache at start?
    autoend = "no",                 -- <no|HH:MM:SS> cache time to stop at
    hostchange = false,             -- <yes|no> use if the host changes mid stream
    quit = "no",                    -- <no|HH:MM:SS> quits player at specified time
}

-- for internal use
local file = {
    name,            -- file name (full path to file)
    path,            -- directory the file is written to
    title,           -- media title
    inc,             -- filename increments
    ext,             -- file extension
    oldtitle,        -- initialized if title is overridden, allows revert
    oldext,          -- initialized if format is overridden, allows revert
    oldpath,         -- initialized if directory is overriden, allows revert
    cache_dumped,    -- whether the current cache has been written
    cache_observed,  -- whether the cache time is being observed
    endseconds,      -- user specified autoend cache time in seconds
    prior_cache = 0, -- previous cache time
    quit_timer,      -- used as a replacement for autoend if hostchange is used
}

local loop = {
    a,               -- A loop point as number type
    b,               -- B loop point as number type
    a_revert,        -- A loop point prior to keyframe alignment
    b_revert,        -- B loop point prior to keyframe alignment
    range,           -- A-B loop range
    aligned,         -- are the loop points aligned to keyframes?
}

local title_change
local container
local chapter_list = {} -- initial chapter list
local ab_chapters = {}  -- A-B loop point chapters
local chapter_points
local convert_time
local observe_cache
local autoquit

local function validate_opts()
    if opts.output_label ~= "increment" and
       opts.output_label ~= "range" and
       opts.output_label ~= "timestamp" and
       opts.output_label ~= "overwrite"
    then
        msg.warn("Invalid output_label '" .. opts.output_label .. "'")
        opts.output_label = "increment"
    end
    if opts.dump_mode ~= "ab" and
       opts.dump_mode ~= "current" and
       opts.dump_mode ~= "continuous"
    then
        msg.warn("Invalid dump_mode '" .. opts.dump_mode .. "'")
        opts.dump_mode = "ab"
    end
end

local function update_opts(changed)
    -- expand mpv meta paths (e.g. ~~/directory)
    file.path = mp.command_native({"expand-path", opts.save_directory})
    if opts.force_title ~= "no" then
        file.title = opts.force_title
        file.inc = file.inc or 1
    elseif changed["force_title"] then
        title_change(_, mp.get_property("media-title"))
    end
    if opts.force_extension ~= "no" then
        file.ext = opts.force_extension
    elseif changed["force_extension"] then
        container()
    end
    if changed["range_marks"] then
        if opts.range_marks then
            chapter_points()
        else
            ab_chapters = {}
            mp.set_property_native("chapter-list", chapter_list)
        end
    end
    if changed["autostart"] or changed["autoend"] or changed["hostchange"] then
        observe_cache()
    end
    validate_opts()
end

options.read_options(opts, "streamsave", update_opts)
update_opts{}

function convert_time(value, quit)
    local H, M, S = value:match("(%d+):(%d+):(%d+)")
    if not (H and M and S) then
        if quit then
            opts.quit = "no"
        else
            file.endseconds = nil
        end
        return
    end
    local compute = H*3600 + M*60 + S
    if quit then
        return compute
    else
        file.endseconds = compute
    end
end

-- dump mode switching
local function mode_switch(value)
    value = value or opts.dump_mode
    if value == "cycle" then
        if opts.dump_mode == "ab" then
            value = "current"
        elseif opts.dump_mode == "current" then
            value = "continuous"
        else
            value = "ab"
        end
    end
    if value == "continuous" then
        opts.dump_mode = "continuous"
        print("Continuous mode")
        mp.osd_message("Cache write mode: Continuous")
    elseif value == "ab" then
        opts.dump_mode = "ab"
        print("A-B loop mode")
        mp.osd_message("Cache write mode: A-B loop")
    elseif value == "current" then
        opts.dump_mode = "current"
        print("Current position mode")
        mp.osd_message("Cache write mode: Current position")
    else
        msg.warn("Invalid dump mode '" .. value .. "'")
    end
end

-- Replacement of reserved file name characters on Windows
function title_change(name, media_title)
    if opts.force_title ~= "no" and not file.oldtitle then
        return end
    if media_title then
        file.title = media_title:gsub("[\\/:*?\"<>|]", ".")
        file.inc = 1
        file.oldtitle = nil
    end
end
mp.observe_property("media-title", "string", title_change)

-- Determine container for standard formats
function container()
    file.cache_dumped = false
    file.prior_cache = 0
    if opts.force_extension ~= "no" and not file.oldext then
        return end
    local file_format = mp.get_property("file-format")
    local video = mp.get_property("video-format")
    local audio = mp.get_property("audio-codec-name")
    if file_format then
        if string.find(file_format, "mp4")
           or ((video == "h264" or video == "av1" or not video) and
               (audio == "aac" or not audio))
        then
            file.ext = ".mp4"
        elseif (video == "vp8" or video == "vp9" or not video)
           and (audio == "opus" or audio == "vorbis" or not audio)
        then
            file.ext = ".webm"
        else
            file.ext = ".mkv"
        end
        file.oldext = nil
    end
end

--[[ video and audio formats observed in order to handle track changes
useful if e.g. --script-opts=ytdl_hook-all_formats=yes
or script-opts=ytdl_hook-use_manifests=yes ]]
mp.observe_property("file-format", "string", container)
mp.observe_property("video-format", "string", container)
mp.observe_property("audio-codec-name", "string", container)

-- Allow user override of file extension
local function format_override(ext)
    ext = ext or file.ext
    file.oldext = file.oldext or file.ext
    if ext == "revert" and file.ext == opts.force_extension then
        container()
    elseif ext == "revert" and opts.force_extension ~= "no" then
        file.ext = opts.force_extension
    elseif ext == "revert" then
        file.ext = file.oldext
    else
        file.ext = ext
    end
    print("file extension changed to " .. file.ext)
    mp.osd_message("streamsave: file extension changed to " .. file.ext)
end

-- Allow user override of title
local function title_override(title)
    title = title or file.title
    file.oldtitle = file.oldtitle or file.title
    if title == "revert" and file.title == opts.force_title then
        title_change(_, mp.get_property("media-title"))
    elseif title == "revert" and opts.force_title ~= "no" then
        file.title = opts.force_title
    elseif title == "revert" then
        file.title = file.oldtitle
    else
        file.title = title
    end
    print("title changed to " .. file.title)
    mp.osd_message("streamsave: title changed to " .. file.title)
end

local function change_path(value)
    value = value or opts.save_directory
    file.oldpath = file.oldpath or opts.save_directory
    if value == "revert" then
        opts.save_directory = file.oldpath
    else
        opts.save_directory = value
    end
    file.path = mp.command_native({"expand-path", opts.save_directory})
    print("Output directory changed to " .. opts.save_directory)
    mp.osd_message("streamsave: directory changed to " .. opts.save_directory)
end

local function change_label(value)
    opts.output_label = value or opts.output_label
    validate_opts()
    print("File label changed to " .. opts.output_label)
    mp.osd_message("streamsave: label changed to " .. opts.output_label)
end

local function change_end(value)
    opts.autoend = value or opts.autoend
    observe_cache()
    if file.endseconds or opts.autoend == "no" then
        print("Autoend set to " .. opts.autoend)
        mp.osd_message("streamsave: autoend set to " .. opts.autoend)
    else
        print("Invalid input '" .. opts.autoend .. "'. Use HH:MM:SS format.")
        mp.osd_message("streamsave: invalid input; use HH:MM:SS format")
    end
end

local function change_hostchange(value)
    if not value or value == "no" then
        opts.hostchange = false
        print("Hostchange disabled")
        mp.osd_message("streamsave: hostchange disabled")
    else
        opts.hostchange = true
        opts.autostart = true
        observe_cache()
        print("Hostchange enabled")
        mp.osd_message("streamsave: hostchange enabled")
    end
end

local function change_quit(value)
    opts.quit = value or opts.quit
    if file.quit_timer and file.quit_timer:is_enabled() then
        file.quit_timer:kill()
    end
    autoquit(convert_time(opts.quit, true))
    print("Quit set to " .. opts.quit)
    mp.osd_message("streamsave: quit set to " .. opts.quit)
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

local function increment_filename()
    file.name = file.path .. "/" .. file.title .. -file.inc .. file.ext
    -- check if file exists
    while utils.file_info(file.name) do
        file.inc = file.inc + 1
        file.name = file.path .. "/" .. file.title .. -file.inc .. file.ext
    end
end

local function range_stamp()
    if opts.dump_mode == "ab" then
        local file_range = "-[" .. loop_range():gsub(":", ".") .. "]"
        file.name = file.path .. "/" .. file.title .. file_range .. file.ext
    elseif opts.dump_mode == "current" then
        local file_pos = mp.get_property_osd("playback-time")
        local file_range = "-[" .. 0 .. " - " .. file_pos:gsub(":", ".") .. "]"
        file.name = file.path .. "/" .. file.title .. file_range .. file.ext
    else
        -- range tag is incompatible with full dump, fallback to increments
        increment_filename()
    end
end

local function cache_write()
    if not (file.title and file.ext) then
        return end
    range_flip()
    -- evaluate tagging conditions and set file name
    if opts.output_label == "increment" then
        increment_filename()
    elseif opts.output_label == "range" then
        range_stamp()
    elseif opts.output_label == "timestamp" then
        file.name = file.path .. "/" .. file.title .. -os.time() .. file.ext
    elseif opts.output_label == "overwrite" then
        file.name = file.path .. "/" .. file.title .. file.ext
    end
    -- dump cache according to mode
    if opts.dump_mode == "ab" then
        mp.commandv("async", "osd-msg", "ab-loop-dump-cache", file.name)
    elseif opts.dump_mode == "current" then
        local file_pos = mp.get_property_number("playback-time")
        mp.commandv("async", "osd-msg", "dump-cache", "0", file_pos, file.name)
    else -- continuous dumping
        mp.commandv("async", "osd-msg", "dump-cache", "0", "no", file.name)
    end
    -- check if file is written
    if utils.file_info(file.name) then
        print("Cache dumped to " .. file.name)
        if opts.output_label == "increment" then
            file.inc = file.inc + 1
        end
        file.cache_dumped = true
    end
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
        mp.commandv("osd-msg", "ab-loop-align-cache")
        loop.aligned = true
        print("Adjusted range: " .. loop_range())
    else
        mp.set_property_native("ab-loop-a", loop.a_revert)
        mp.set_property_native("ab-loop-b", loop.b_revert)
        loop.aligned = false
        print("Loop points reverted to: " .. loop_range())
        mp.osd_message("A-B loop: " .. loop.range)
    end
end

-- creates chapters at A-B loop points
function chapter_points()
    if not opts.range_marks then
        return end
    local current_chapters = mp.get_property_native("chapter-list")
    -- make sure master list is up to date
    if current_chapters[1] and
       not string.match(current_chapters[1]["title"], "^[AB] loop point$")
    then
        chapter_list = current_chapters
    -- if a script has added chapters after A-B points are set then
    -- add those to the original chapter list
    elseif #current_chapters > #ab_chapters then
        for i = #ab_chapters + 1, #current_chapters do
            table.insert(chapter_list, current_chapters[i])
        end
    end
    ab_chapters = {}
    -- restore original chapter list if A-B points are cleared
    -- otherwise set chapters to A-B points
    if loop_range() == "no - no" then
        mp.set_property_native("chapter-list", chapter_list)
    else
        range_flip()
        if loop.a then
            ab_chapters[1] = {
                title = "A loop point",
                time = loop.a
            }
        end
        if loop.b and not loop.a then
            ab_chapters[1] = {
                title = "B loop point",
                time = loop.b
            }
        elseif loop.b then
            ab_chapters[2] = {
                title = "B loop point",
                time = loop.b
            }
        end
        mp.set_property_native("chapter-list", ab_chapters)
    end
end

--[[ Loading chapters can be slow especially if they're passed from
an external file, so make sure existing chapters are not overwritten
by observing A-B loop changes only after the file is loaded. ]]
local function on_file_load()
    mp.observe_property("ab-loop-a", "native", chapter_points)
    mp.observe_property("ab-loop-b", "native", chapter_points)
end
mp.register_event("file-loaded", on_file_load)

-- stops writing the file
local function stop()
    mp.commandv("async", "osd-msg", "dump-cache", "0", "no", "")
end

local function automatic(_, value)
    if opts.hostchange and file.prior_cache ~= 0
       and (not value or math.abs(value - file.prior_cache) > 300)
    then
        -- reload stream
        mp.command("playlist-play-index current")
        return
    elseif not value then
        return
    end
    if opts.autostart and not file.cache_dumped then
        opts.dump_mode = "continuous"
        cache_write()
    end
    if not file.endseconds and not opts.hostchange then
        mp.unobserve_property(automatic)
        file.cache_observed = false
    end
    if file.endseconds and file.cache_dumped and value >= file.endseconds then
        stop()
        mp.unobserve_property(automatic)
        file.cache_observed = false
        file.cache_dumped = false
    end
    file.prior_cache = value
end

-- cache duration observation switch for runtime changes
function observe_cache()
    convert_time(opts.autoend)
    if not file.cache_observed and (opts.autostart or file.endseconds) then
        mp.observe_property("demuxer-cache-time", "number", automatic)
        file.cache_observed = true
    end
end
observe_cache()

function autoquit(value)
    if opts.quit == "no" then
        return
    end
    file.quit_timer = mp.add_timeout(value, function() mp.command("quit")
                                     print("Quit after " .. opts.quit)
                                     end)
end
autoquit(convert_time(opts.quit, true))

mp.register_script_message("streamsave-mode", mode_switch)
mp.register_script_message("streamsave-title", title_override)
mp.register_script_message("streamsave-extension", format_override)
mp.register_script_message("streamsave-path", change_path)
mp.register_script_message("streamsave-label", change_label)
mp.register_script_message("streamsave-autoend", change_end)
mp.register_script_message("streamsave-hostchange", change_hostchange)
mp.register_script_message("streamsave-quit", change_quit)

mp.add_key_binding("Alt+z", "mode-switch", function() mode_switch("cycle") end)
mp.add_key_binding("Ctrl+x", "stop-cache-write", stop)
mp.add_key_binding("Alt+x", "align-cache", align_cache)
mp.add_key_binding("Ctrl+z", "cache-write", cache_write)
