--[[ 

streamsave.lua
Version 0.22.0
2023-3-30
https://github.com/Sagnac/streamsave

mpv script aimed at saving live streams and clipping online videos without encoding.

Essentially a wrapper around mpv's cache dumping commands, the script adds the following functionality:

* Automatic determination of the output file name and format
* Option to specify the preferred output directory
* Switch between 5 different dump modes:
 (clip mode, full/continuous dump, write from beginning to current position, current chapter, all chapters)
* Prevention of file overwrites
* Acceptance of inverted loop ranges, allowing the end point to be set first
* Dynamic chapter indicators on the OSC displaying the clipping interval
* Option to track HLS packet drops
* Automated stream saving
* Workaround for some DAI HLS streams served from .m3u8 where the host changes

By default the A-B loop points (set using the `l` key in mpv) determine the portion of the cache written to disk.

It is advisable that you set --demuxer-max-bytes and --demuxer-max-back-bytes to larger values
(e.g. at least 1GiB) in order to have a larger cache.
If you want to use with local files set cache=yes in mpv.conf

Options are specified in ~~/script-opts/streamsave.conf

Runtime changes to all user options are supported via the `script-opts` property by using mpv's `set` or
`change-list` input commands and the `streamsave-` prefix.

General Options:

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

dump_mode=chapter will write the current chapter to file.

dump_mode=segments writes out all chapters to individual files.

If you wish to output a single chapter using a numerical input instead you can specify it with a command at runtime:
script-message streamsave-chapter 7

The output_label option allows you to choose how the output filename is tagged.
The default uses iterated step increments for every file output; i.e. file-1.mkv, file-2.mkv, etc.

There are 4 other choices:

output_label=timestamp will append Unix timestamps to the file name.

output_label=range will tag the file with the A-B loop range instead using the format HH.MM.SS
e.g. file-[00.15.00 - 00.20.00].mkv

output_label=overwrite will not tag the file and will overwrite any existing files with the same name.

output_label=chapter uses the chapter title for the file name if using one of the chapter modes.

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
This option is disabled by default; set range_marks=yes in streamsave.conf in order to enable it.

The track_packets option adds chapters to positions where packet loss occurs for HLS streams.

Automation Options:

The autostart and autoend options are used for automated stream capturing.
Set autostart=yes if you want the script to trigger cache writing immediately on stream load.
Set autoend to a time format of the form HH:MM:SS (e.g. autoend=01:20:08) if you want the file writing
to stop at that time.

The hostchange option enables an experimental workaround for DAI HLS .m3u8 streams in which the host changes.
If enabled this will result in multiple files being output as the stream reloads.
The autostart option must also be enabled in order to autosave these types of streams.

The `quit=HH:MM:SS` option will set a one shot timer from script load to the specified time,
at which point the player will exit. This serves as a replacement for autoend when using hostchange.
Running `script-message streamsave-quit HH:MM:SS` at runtime will reset and restart the timer.

Set piecewise=yes if you want to save a stream in parts automatically, useful for
e.g. saving long streams on slow systems. Set autoend to the duration preferred for each output file.
This feature requires autostart=yes.

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

local unpack = unpack or table.unpack

-- default user options
-- change these in streamsave.conf
local opts = {
    save_directory = [[.]],         -- output file directory
    dump_mode = "ab",               -- <ab|current|continuous|chapter|segments>
    output_label = "increment",     -- <increment|range|timestamp|overwrite|chapter>
    force_extension = "no",         -- <no|.ext> extension will be .ext if set
    force_title = "no",             -- <no|title> custom title used for the filename
    range_marks = false,            -- <yes|no> set chapters at A-B loop points?
    track_packets = false,          -- <yes|no> track HLS packet drops
    autostart = false,              -- <yes|no> automatically dump cache at start?
    autoend = "no",                 -- <no|HH:MM:SS> cache time to stop at
    hostchange = false,             -- <yes|no> use if the host changes mid stream
    quit = "no",                    -- <no|HH:MM:SS> quits player at specified time
    piecewise = false,              -- <yes|no> writes stream in parts with autoend
}

-- for internal use
local file = {
    name,            -- file name (full path to file)
    path,            -- directory the file is written to
    title,           -- media title
    inc,             -- filename increments
    ext,             -- file extension
    loaded,          -- flagged once the initial load has taken place
    pending,         -- number of files pending write completion (max 2)
    queue,           -- cache_write queue in case of multiple write requests
    writing,         -- file writing object returned by the write command
    quitsec,         -- user specified quit time in seconds
    quit_timer,      -- player quit timer set according to quitsec
    oldtitle,        -- initialized if title is overridden, allows revert
    oldext,          -- initialized if format is overridden, allows revert
    oldpath,         -- initialized if directory is overriden, allows revert
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

local cache = {
    dumped,          -- autowrite cache state (serves as an autowrite request)
    observed,        -- whether the cache time is being observed
    endsec,          -- user specified autoend cache time in seconds
    prior,           -- previous cache time
    seekend,         -- seekable cache end timestamp
    part,            -- approx. end time of last piece / start time of next piece
    switch,          -- request to observe track switches and seeking
    use,             -- use cache_time instead of seekend for initial piece
    restart,         -- hostchange interval where subsequent reloads are immediate
    id,              -- number of times the packet tracking event has fired
    packets,         -- table of periodic timers indexed by cache id stamps
    playtime,        -- previous playback-time for auto reload checks
}

local segments = {}     -- chapter segments set for writing
local chapter_list = {} -- initial chapter list
local ab_chapters = {}  -- A-B loop point chapters

local title_change
local container
local get_chapters
local chapter_points
local reset
local get_seekable_cache
local reload
local automatic
local autoquit
local packet_events
local observe_cache

local function convert_time(value)
    local H, M, S = value:match("^(%d+):([0-5]%d):([0-5]%d)$")
    if H then
        return H*3600 + M*60 + S
    end
end

local function validate_opts()
    if opts.output_label ~= "increment" and
       opts.output_label ~= "range" and
       opts.output_label ~= "timestamp" and
       opts.output_label ~= "overwrite" and
       opts.output_label ~= "chapter"
    then
        msg.error("Invalid output_label '" .. opts.output_label .. "'")
        opts.output_label = "increment"
    end
    if opts.dump_mode ~= "ab" and
       opts.dump_mode ~= "current" and
       opts.dump_mode ~= "continuous" and
       opts.dump_mode ~= "chapter" and
       opts.dump_mode ~= "segments"
    then
        msg.error("Invalid dump_mode '" .. opts.dump_mode .. "'")
        opts.dump_mode = "ab"
    end
    if opts.autoend ~= "no" then
        if not cache.part then
            cache.endsec = convert_time(opts.autoend)
        end
        if not convert_time(opts.autoend) then
            msg.error("Invalid autoend value '" .. opts.autoend ..
                     "'. Use HH:MM:SS format.")
            opts.autoend = "no"
        end
    end
    if opts.quit ~= "no" then
        file.quitsec = convert_time(opts.quit)
        if not file.quitsec then
            msg.error("Invalid quit value '" .. opts.quit ..
                     "'. Use HH:MM:SS format.")
            opts.quit = "no"
        end
    end
end

local function update_opts(changed)
    validate_opts()
    -- expand mpv meta paths (e.g. ~~/directory)
    file.path = mp.command_native({"expand-path", opts.save_directory})
    if opts.force_title ~= "no" then
        file.title = opts.force_title
    elseif changed["force_title"] then
        title_change(_, mp.get_property("media-title"), true)
    end
    if opts.force_extension ~= "no" then
        file.ext = opts.force_extension
    elseif changed["force_extension"] then
        container(_, _, true)
    end
    if changed["range_marks"] then
        if opts.range_marks then
            chapter_points()
        else
            if not get_chapters() then
                mp.set_property_native("chapter-list", chapter_list)
            end
            ab_chapters = {}
        end
    end
    if changed["autoend"] then
        cache.endsec = convert_time(opts.autoend)
        observe_cache()
    end
    if changed["autostart"] or changed["hostchange"] then
        observe_cache()
    end
    if changed["quit"] then
        autoquit()
    end
    if changed["piecewise"] and not opts.piecewise then
        cache.part = 0
    elseif changed["piecewise"] then
        cache.endsec = convert_time(opts.autoend)
    end
    if changed["track_packets"] then
        packet_events(opts.track_packets)
    end
end

options.read_options(opts, "streamsave", update_opts)
update_opts{}

-- dump mode switching
local function mode_switch(value)
    value = value or opts.dump_mode
    if value == "cycle" then
        if opts.dump_mode == "ab" then
            value = "current"
        elseif opts.dump_mode == "current" then
            value = "continuous"
        elseif opts.dump_mode == "continuous" then
            value = "chapter"
        elseif opts.dump_mode == "chapter" then
            value = "segments"
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
    elseif value == "chapter" then
        opts.dump_mode = "chapter"
        print("Chapter mode (single chapter)")
        mp.osd_message("Cache write mode: Chapter")
    elseif value == "segments" then
        opts.dump_mode = "segments"
        print("Segments mode (all chapters)")
        mp.osd_message("Cache write mode: Segments")
    else
        msg.error("Invalid dump mode '" .. value .. "'")
    end
end

-- Set the principal part of the file name using the media title
function title_change(_, media_title, req)
    if opts.force_title ~= "no" and not req then
        file.title = opts.force_title
        return end
    if media_title then
        -- Replacement of reserved file name characters on Windows
        file.title = media_title:gsub("[\\/:*?\"<>|]", ".")
        file.oldtitle = nil
    end
end

-- Determine container for standard formats
function container(_, _, req)
    local audio = mp.get_property("audio-codec-name")
    local video = mp.get_property("video-format")
    local file_format = mp.get_property("file-format")
    if not file_format then
        reset()
        return end
    if opts.force_extension ~= "no" and not req then
        file.ext = opts.force_extension
        observe_cache()
        return end
    if string.match(file_format, "mp4")
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
    observe_cache()
    file.oldext = nil
end

local function format_override(ext)
    ext = ext or file.ext
    file.oldext = file.oldext or file.ext
    if ext == "revert" and file.ext == opts.force_extension then
        container(_, _, true)
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

local function title_override(title)
    title = title or file.title
    file.oldtitle = file.oldtitle or file.title
    if title == "revert" and file.title == opts.force_title then
        title_change(_, mp.get_property("media-title"), true)
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

local function path_override(value)
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

local function label_override(value)
    if value == "cycle" then
        if opts.output_label == "increment" then
            value = "range"
        elseif opts.output_label == "range" then
            value = "timestamp"
        elseif opts.output_label == "timestamp" then
            value = "overwrite"
        elseif opts.output_label == "overwrite" then
            value = "chapter"
        else
            value = "increment"
        end
    end
    opts.output_label = value or opts.output_label
    validate_opts()
    print("File label changed to " .. opts.output_label)
    mp.osd_message("streamsave: label changed to " .. opts.output_label)
end

local function marks_override(value)
    if not value or value == "no" then
        opts.range_marks = false
        if not get_chapters() then
            mp.set_property_native("chapter-list", chapter_list)
        end
        ab_chapters = {}
        print("Range marks disabled")
        mp.osd_message("streamsave: range marks disabled")
    elseif value == "yes" then
        opts.range_marks = true
        chapter_points()
        print("Range marks enabled")
        mp.osd_message("streamsave: range marks enabled")
    else
        msg.error("Invalid input '" .. value .. "'. Use yes or no.")
        mp.osd_message("streamsave: invalid input; use yes or no")
    end
end

local function autostart_override(value)
    if not value or value == "no" then
        opts.autostart = false
        print("Autostart disabled")
        mp.osd_message("streamsave: autostart disabled")
    elseif value == "yes" then
        opts.autostart = true
        print("Autostart enabled")
        mp.osd_message("streamsave: autostart enabled")
    else
        msg.error("Invalid input '" .. value .. "'. Use yes or no.")
        mp.osd_message("streamsave: invalid input; use yes or no")
        return
    end
    observe_cache()
end

local function autoend_override(value)
    opts.autoend = value or opts.autoend
    validate_opts()
    cache.endsec = convert_time(opts.autoend)
    observe_cache()
    print("Autoend set to " .. opts.autoend)
    mp.osd_message("streamsave: autoend set to " .. opts.autoend)
end

local function hostchange_override(value)
    value = value == "cycle" and (not opts.hostchange and "yes" or "no") or value
    if not value or value == "no" then
        opts.hostchange = false
        mp.unobserve_property(reload)
        local timer = cache.restart and cache.restart:kill()
        print("Hostchange disabled")
        mp.osd_message("streamsave: hostchange disabled")
    elseif value == "yes" then
        opts.hostchange = true
        print("Hostchange enabled")
        mp.osd_message("streamsave: hostchange enabled")
    else
        msg.error("Invalid input '" .. value .. "'. Use yes or no.")
        mp.osd_message("streamsave: invalid input; use yes or no")
        return
    end
    observe_cache()
end

local function quit_override(value)
    opts.quit = value or opts.quit
    validate_opts()
    autoquit()
    print("Quit set to " .. opts.quit)
    mp.osd_message("streamsave: quit set to " .. opts.quit)
end

local function piecewise_override(value)
    if not value or value == "no" then
        opts.piecewise = false
        cache.part = 0
        print("Piecewise dumping disabled")
        mp.osd_message("streamsave: piecewise dumping disabled")
    elseif value == "yes" then
        opts.piecewise = true
        cache.endsec = convert_time(opts.autoend)
        print("Piecewise dumping enabled")
        mp.osd_message("streamsave: piecewise dumping enabled")
    else
        msg.error("Invalid input '" .. value .. "'. Use yes or no.")
        mp.osd_message("streamsave: invalid input; use yes or no")
    end
end

local function packet_override(value)
    local track_packets = opts.track_packets
    if value == "cycle" then
        value = not track_packets and "yes" or "no"
    end
    if not value or value == "no" then
        opts.track_packets = false
        print("Track packets disabled")
        mp.osd_message("streamsave: track packets disabled")
    elseif value == "yes" then
        opts.track_packets = true
        print("Track packets enabled")
        mp.osd_message("streamsave: track packets enabled")
    else
        msg.error("Invalid input '" .. value .. "'. Use yes or no.")
        mp.osd_message("streamsave: invalid input; use yes or no")
    end
    if opts.track_packets ~= track_packets then
        packet_events(opts.track_packets)
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

local function set_name(label)
    return file.path .. "/" .. file.title .. label .. file.ext
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

local function write_chapter(chapter)
    get_chapters()
    if chapter_list[chapter] or chapter == 0 then
        segments[1] = {
            ["start"] = chapter == 0 and 0 or chapter_list[chapter]["time"],
            ["end"] = chapter_list[chapter + 1]
                      and chapter_list[chapter + 1]["time"]
                      or mp.get_property_number("duration", "no"),
            ["title"] = chapter .. ". " .. (chapter ~= 0
                        and chapter_list[chapter]["title"] or file.title)
        }
        print("Writing chapter " .. chapter .. " ....")
        return true
    else
        msg.error("Chapter not found.")
    end
end

local function extract_segments(n)
    for i = 1, n - 1 do
        segments[i] = {
            ["start"] = chapter_list[i]["time"],
            ["end"] = chapter_list[i + 1]["time"],
            ["title"] = i .. ". " .. (chapter_list[i]["title"] or file.title)
        }
    end
    if chapter_list[1]["time"] ~= 0 then
        table.insert(segments, 1, {
            ["start"] = 0,
            ["end"] = chapter_list[1]["time"],
            ["title"] = "0. " .. file.title
        })
    end
    table.insert(segments, {
        ["start"] = chapter_list[n]["time"],
        ["end"] = mp.get_property_number("duration", "no"),
        ["title"] = n .. ". " .. (chapter_list[n]["title"] or file.title)
    })
    print("Writing out all " .. #segments .. " chapters to separate files ....")
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
    elseif (mode == "chapter" or mode == "segments") and segments[1] then
        command["name"] = "dump-cache"
        command["start"] = segments[1]["start"]
        command["end"] = segments[1]["end"]
        table.remove(segments, 1)
    else
        command["name"] = "dump-cache"
        command["start"] = 0
        command["end"] = file_pos or "no"
    end
    return command
end

local function on_write_finish(cache_write, mode, file_name)
    return function(success, _, command_error)
        command_error = command_error and msg.error(command_error)
        -- check if file is written
        if utils.file_info(file_name) then
            if success then
                print("Finished writing cache to: " .. file_name)
            else
                msg.warn("Possibly broken file created at: " .. file_name)
            end
        else
            msg.error("File not written.")
        end
        if loop.continuous and file.pending == 2 then
            print("Dumping cache continuously to: " .. file.name)
        end
        file.pending = file.pending - 1
        -- fulfil any write requests now that the pending queue has been serviced
        if next(segments) then
            cache_write("segments", true)
        elseif mode == "segments" then
            mp.osd_message("Cache dumping successfully ended.")
        end
        if file.queue and next(file.queue) and not segments[1] then
            cache_write(unpack(file.queue[1]))
            table.remove(file.queue, 1)
        end
    end
end

local function cache_write(mode, quiet, chapter)
    if not (file.title and file.ext) then
        return end
    if file.pending == 2
       or segments[1] and file.pending > 0 and not loop.continuous
    then
        file.queue = file.queue or {}
        -- honor extra write requests when pending queue is full
        -- but limit number of outstanding write requests to be fulfilled
        if #file.queue < 10 then
            table.insert(file.queue, {mode, quiet, chapter})
        end
        return end
    range_flip()
    -- set the output list for the chapter modes
    if mode == "segments" and not segments[1] then
        get_chapters()
        local n = #chapter_list
        if n > 0 then
            extract_segments(n)
            quiet = true
            mp.osd_message("Cache dumping started.")
        else
            mode = "continuous"
        end
    elseif mode == "chapter" and not segments[1] then
        chapter = chapter or mp.get_property_number("chapter", -1) + 1
        if not write_chapter(chapter) then
            return
        end
    end
    -- evaluate tagging conditions and set file name
    if opts.output_label == "increment" then
        increment_filename()
    elseif opts.output_label == "range" then
        range_stamp(mode)
    elseif opts.output_label == "timestamp" then
        file.name = set_name(-os.time())
    elseif opts.output_label == "overwrite" then
        file.name = set_name("")
    elseif opts.output_label == "chapter" then
        if segments[1] then
            file.name = file.path .. "/" .. segments[1]["title"] .. file.ext
        else
            increment_filename()
        end
    end
    -- dump cache according to mode
    local file_pos
    file.pending = (file.pending or 0) + 1
    loop.continuous = mode == "continuous"
                      or mode == "ab" and loop.a and not loop.b
                      or segments[1] and segments[1]["end"] == "no"
    if mode == "current" then
        file_pos = mp.get_property_number("playback-time", 0)
    elseif loop.continuous and file.pending == 1 then
        print("Dumping cache continuously to: " .. file.name)
    end
    local commands = write_set(mode, file.name, file_pos, quiet)
    local callback = on_write_finish(cache_write, mode, file.name)
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
        print("Adjusted range: " .. loop_range())
    else
        mp.set_property_native("ab-loop-a", loop.a_revert)
        mp.set_property_native("ab-loop-b", loop.b_revert)
        loop.aligned = false
        print("Loop points reverted to: " .. loop_range())
        mp.osd_message("A-B loop: " .. loop.range)
    end
end

function get_chapters()
    local current_chapters = mp.get_property_native("chapter-list", {})
    local updated -- do the stored chapters reflect the current chapters ?
    -- make sure master list is up to date
    if not current_chapters[1] or
       not string.match(current_chapters[1]["title"], "^[AB] loop point$")
    then
        chapter_list = current_chapters
        updated = true
    -- if a script has added chapters after A-B points are set then
    -- add those to the original chapter list
    elseif #current_chapters > #ab_chapters then
        for i = #ab_chapters + 1, #current_chapters do
            table.insert(chapter_list, current_chapters[i])
        end
    end
    return updated
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
    else
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

-- stops writing the file
local function stop()
    mp.abort_async_command(file.writing or {})
end

function reset()
    if cache.observed or cache.dumped then
        stop()
        mp.unobserve_property(automatic)
        mp.unobserve_property(reload)
        mp.unobserve_property(get_seekable_cache)
        cache.endsec = convert_time(opts.autoend)
        cache.observed = false
    end
    cache.prior = 0
    cache.part = 0
    cache.dumped = false
    cache.switch = true
end
reset()

function get_seekable_cache(prop, range_check, underrun)
    -- use the seekable part of the cache for more accurate timestamps
    local cache_state = mp.get_property_native("demuxer-cache-state", {})
    if underrun then
        return cache_state["underrun"]
    end
    local seekable_ranges = cache_state["seekable-ranges"] or {}
    if prop then
        if range_check ~= false and
           (#seekable_ranges == 0
            or not cache_state["cache-end"])
        then
            reset()
            cache.use = opts.piecewise
            observe_cache()
        end
        return
    end
    local seekable_ends = {0}
    for i, range in ipairs(seekable_ranges) do
        seekable_ends[i] = range["end"] or 0
    end
    cache.seekend = math.max(0, unpack(seekable_ends))
    return cache.seekend
end

function reload(_, play_time)
    local cache_duration = mp.get_property_number("demuxer-cache-duration")
    local seeking = mp.get_property_bool("seeking")
    play_time = math.abs(play_time or 0)
    if play_time >= cache.seekend - 0.25
       or cache_duration and math.abs(cache.prior - cache_duration) > 4800
       or get_seekable_cache(nil, false, true)
       or cache.playtime and math.abs(play_time - cache.playtime) > 7
          and not seeking
    then
        reset()
        cache.playtime = nil
        cache.restart = cache.restart or mp.add_timeout(300, function() end)
        cache.restart:resume()
        msg.warn("Reloading stream due to host change.")
        mp.command("playlist-play-index current")
        return
    end
    cache.playtime = play_time
end

function automatic(_, cache_time)
    if opts.hostchange and cache.prior ~= 0
       and (not cache_time or math.abs(cache_time - cache.prior) > 300
            or mp.get_property_number("demuxer-cache-duration", 0) > 11000
            or cache.restart and cache.restart:is_enabled() and
               get_seekable_cache(nil, false, true))
       and not mp.get_property_bool("seeking")
    then
        if not cache.restart or not cache.restart:is_enabled() then
            reset()
            cache.observed = true
            cache.prior = mp.get_property_number("demuxer-cache-duration", 0)
            get_seekable_cache()
            mp.observe_property("playback-time", "number", reload)
        else
            -- reload stream
            cache.restart:kill()
            reset()
            msg.warn("Reloading stream due to host change.")
            mp.command("playlist-play-index current")
        end
        return
    elseif not cache_time then
        reset()
        cache.use = opts.piecewise
        observe_cache()
        return
    end
    -- cache write according to automatic options
    if opts.autostart and not cache.dumped
       and (not cache.endsec or cache_time < cache.endsec
            or opts.piecewise)
    then
        if opts.piecewise and cache.part ~= 0 then
            cache.dumped = cache_write("ab")
        else
            cache.dumped = cache_write("continuous", opts.hostchange)
            -- update the piece time if there's a track/seeking reset
            cache.part = cache.use and cache.dumped and cache_time or 0
            cache.use = cache.use and cache.part == 0
        end
    end
    -- the seekable ranges update slowly, which is why they're used to check
    -- against switches for increased certainty, but this means the switch properties
    -- should be watched only when the ranges exist
    if cache.switch and get_seekable_cache() ~= 0 then
        cache.switch = false
        mp.observe_property("current-tracks/audio/id", "number", get_seekable_cache)
        mp.observe_property("current-tracks/video/id", "number", get_seekable_cache)
        mp.observe_property("seeking", "bool", get_seekable_cache)
    end
    -- unobserve cache time if not needed
    if cache.dumped and not cache.switch
       and not cache.endsec and not opts.hostchange
    then
        mp.unobserve_property(automatic)
        cache.observed = false
        cache.prior = 0
        return
    end
    -- stop cache dump
    if cache.endsec and cache.dumped and
       cache_time - cache.part >= cache.endsec
    then
        if opts.piecewise then
            cache.part = get_seekable_cache()
            mp.set_property_number("ab-loop-a", cache.part)
            mp.set_property("ab-loop-b", "no")
            -- try and make the next piece start on the final keyframe of this piece
            loop.aligned = false
            align_cache()
            cache.dumped = false
        else
            cache.endsec = nil
        end
        stop()
    end
    cache.prior = cache_time
end

function autoquit()
    if opts.quit == "no" then
        if file.quit_timer then
            file.quit_timer:kill()
        end
    elseif not file.quit_timer then
        file.quit_timer = mp.add_timeout(file.quitsec,
            function()
                stop()
                mp.command("quit")
                print("Quit after " .. opts.quit)
            end)
    else
        file.quit_timer["timeout"] = file.quitsec
        file.quit_timer:kill()
        file.quit_timer:resume()
    end
end
autoquit()

local function fragment_chapters(packets, cache_time, stamp)
    local no_loop_chapters = get_chapters()
    local title = string.format("%s segment(s) dropped [%s]", packets, stamp)
    for _, chapter in ipairs(chapter_list) do
        if chapter["title"] == title then
            cache.packets[stamp]:kill()
            cache.packets[stamp] = nil
            return
        end
    end
    table.insert(chapter_list, {
        title = title,
        time = cache_time
    })
    if no_loop_chapters then
        mp.set_property_native("chapter-list", chapter_list)
    end
end

local function packet_handler(t)
    if not opts.track_packets then -- second layer in case unregistering is async
        return
    end
    if t.prefix == "ffmpeg/demuxer" then
        local packets = t.text:match("^hls: skipping (%d+)")
        if packets then
            local cache_time = mp.get_property_number("demuxer-cache-time")
            if cache_time then
                -- ensure the chapters set
                cache.id = cache.id + 1
                local stamp = string.format("%#x", cache.id)
                cache.packets[stamp] = mp.add_periodic_timer(3,
                    function()
                        fragment_chapters(packets, cache_time, stamp)
                    end
                )
            end
        end
    end
end

function packet_events(state)
    if not state then
        mp.unregister_event(packet_handler)
        for _, timer in pairs(cache.packets) do
            timer:kill()
        end
        cache.id = nil
        cache.packets = nil
        local no_loop_chapters = get_chapters()
        local n = #chapter_list
        for i = n, 1, -1 do
            if chapter_list[i]["title"]:match("%d+ segment%(s%) dropped") then
                table.remove(chapter_list, i)
            end
        end
        if no_loop_chapters and n > #chapter_list then
            mp.set_property_native("chapter-list", chapter_list)
        end
    else
        cache.id = 0
        cache.packets = {}
        mp.enable_messages("warn")
        mp.register_event("log-message", packet_handler)
    end
end
if opts.track_packets then
    packet_events(true)
end

-- cache time observation switch for runtime changes
function observe_cache()
    local network = mp.get_property_bool("demuxer-via-network")
    local obs_xyz = opts.autostart or cache.endsec or opts.hostchange
    if not cache.observed and obs_xyz and network then
        mp.observe_property("demuxer-cache-time", "number", automatic)
        cache.observed = true
    elseif (cache.observed or cache.dumped) and (not obs_xyz or not network) then
        reset()
    end
end

mp.observe_property("media-title", "string", title_change)

--[[ video and audio formats observed in order to handle track changes
useful if e.g. --script-opts=ytdl_hook-all_formats=yes
or script-opts=ytdl_hook-use_manifests=yes ]]
mp.observe_property("audio-codec-name", "string", container)
mp.observe_property("video-format", "string", container)
mp.observe_property("file-format", "string", container)

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
mp.register_script_message("streamsave-title", title_override)
mp.register_script_message("streamsave-extension", format_override)
mp.register_script_message("streamsave-path", path_override)
mp.register_script_message("streamsave-label", label_override)
mp.register_script_message("streamsave-marks", marks_override)
mp.register_script_message("streamsave-autostart", autostart_override)
mp.register_script_message("streamsave-autoend", autoend_override)
mp.register_script_message("streamsave-hostchange", hostchange_override)
mp.register_script_message("streamsave-quit", quit_override)
mp.register_script_message("streamsave-piecewise", piecewise_override)
mp.register_script_message("streamsave-packets", packet_override)
mp.register_script_message("streamsave-chapter",
    function(chapter)
        cache_write("chapter", _, tonumber(chapter))
    end
)

mp.add_key_binding("Alt+z", "mode-switch", function() mode_switch("cycle") end)
mp.add_key_binding("Ctrl+x", "stop-cache-write", stop)
mp.add_key_binding("Alt+x", "align-cache", align_cache)
mp.add_key_binding("Ctrl+z", "cache-write",
                   function() cache_write(opts.dump_mode)
                   end)
