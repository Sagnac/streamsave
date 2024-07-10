--[[

streamsave.lua
Version 0.28.0
2024-07-18
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

Runtime updates to all user options are also supported via the `script-opts` property by using mpv's `set` or
`change-list` input commands and the `streamsave-` prefix.

General Options:

save_directory sets the output file directory. Paths with or without a trailing slash are accepted.
Don't use quote marks when specifying paths here.
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

fallback_write=yes enables initiation of full continuous writes under A-B loop mode if no loop points are set.

The output_label option allows you to choose how the output filename is tagged.
The default uses iterated step increments for every file output; i.e. file-1.mkv, file-2.mkv, etc.

There are 4 other choices:

output_label=timestamp will use a Unix timestamp for the file name.

output_label=range will tag the file with the A-B loop range instead using the format HH.MM.SS
e.g. file-[00.15.00 - 00.20.00].mkv

output_label=overwrite will not tag the file and will overwrite any existing files with the same name.

output_label=chapter uses the chapter title for the file name if using one of the chapter modes.

The force_extension option allows you to force a preferred format and sidestep the automatic detection.
If using this option it is recommended that a highly flexible container is used (e.g. Matroska).
The format is specified as the extension including the dot (e.g. force_extension=.mkv).

This option can be set at runtime with script-message by passing force as an argument; e.g.:
script-message streamsave-extension .mkv force
This changes the format for the current stream and all subsequently loaded streams
(without `force` the setting is a one-shot setting for the present stream).

If this option is set, `script-message streamsave-extension revert` will run the automatic determination at runtime;
running this command again will reset the extension to what's specified in force_extension.

The force_title option will set the title used for the filename. By default the script uses the media-title.
This is specified without double quote marks in streamsave.conf, e.g. force_title=Example Title
The output_label is still used here and file overwrites are prevented if desired.
Changing the filename title to the media-title is still possible at runtime by using the revert argument,
as in the force_extension example.
The secondary `force` argument is supported as well when not using `revert`.
Property expansion is supported for all user-set titles. For example:
`force_title=streamsave_${media-title}` in streamsave.conf, or
`script-message streamsave-title ${duration}` at runtime.

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
The `on_demand` option is a suboption of the hostchange option which, if enabled, triggers reloads immediately across
segment switches without waiting until playback has reached the end of the last segment.

The `quit=HH:MM:SS` option will set a one shot timer from script load to the specified time,
at which point the player will exit. This serves as a replacement for autoend when using hostchange.
Running `script-message streamsave-quit HH:MM:SS` at runtime will reset and restart the timer.

Set piecewise=yes if you want to save a stream in parts automatically, useful for
e.g. saving long streams on slow systems. Set autoend to the duration preferred for each output file.
This feature requires autostart=yes.

mpv's script-message command can be used to change settings at runtime and
temporarily override the output title or file extension.
Boolean-style options (yes/no) can be cycled by omitting the third argument.
If you override the title, the file extension, or the directory, the revert argument can be used
to set it back to the default value.

Examples:
script-message streamsave-marks
script-message streamsave-mode continuous
script-message streamsave-title "Global Title" force
script-message streamsave-title "Example Title"
script-message streamsave-extension .mkv
script-message streamsave-extension revert
script-message streamsave-path ~/streams
script-message streamsave-label range

]]

local options = require 'mp.options'
local utils = require 'mp.utils'
local msg = require 'mp.msg'

-- compatibility with Lua 5.1 (these are present in 5.2+ and LuaJIT)
local pack = table.pack or function(...) return {n = select("#", ...), ...} end
local unpack = unpack or table.unpack

-- default user settings
-- change these in streamsave.conf
local opts = {
    save_directory  = [[]],        -- output file directory
    dump_mode       = "ab",        -- <ab|current|continuous|chapter|segments>
    fallback_write  = false,       -- <yes|no> full dump if no loop points are set
    output_label    = "increment", -- <increment|range|timestamp|overwrite|chapter>
    force_extension = "",          -- <.ext> extension will be .ext if set
    force_title     = "",          -- <title> custom title used for the filename
    range_marks     = false,       -- <yes|no> set chapters at A-B loop points?
    track_packets   = false,       -- <yes|no> track HLS packet drops
    autostart       = false,       -- <yes|no> automatically dump cache at start?
    autoend         = "no",        -- <no|HH:MM:SS> cache time to stop at
    hostchange      = false,       -- <yes|no> use if the host changes mid stream
    on_demand       = false,       -- <yes|no> hostchange suboption, instant reloads
    quit            = "no",        -- <no|HH:MM:SS> quits player at specified time
    piecewise       = false,       -- <yes|no> writes stream in parts with autoend
}

local cycle = {}

cycle.modes = {
    "ab",
    "current",
    "continuous",
    "chapter",
    "segments",
}

local mode_info = {
    continuous = "Continuous",
    ab = "A-B loop",
    current = "Current position",
    chapter = "Chapter",
    segments = "Segments",
    append = {
        chapter = " (single chapter)",
        segments = " (all chapters)"
    }
}

cycle.labels = {
    "increment",
    "range",
    "timestamp",
    "overwrite",
    "chapter",
}

function cycle.set(s)
    local opt = {}
    for i, v in ipairs(cycle[s]) do
        opt[v] = i
    end
    local mt = {
        __index = function(t) return t[1] end,
        __call  = function(t, v) return t[opt[v] + 1] end
    }
    setmetatable(cycle[s], mt)
    return opt
end

local modes = cycle.set("modes")
local labels = cycle.set("labels")

-- for internal use
local file = {
    name,            -- file name (path to file)
    path,            -- directory the file is written to
    title,           -- media title
    inc,             -- filename increments
    ext,             -- file extension
    length,          -- 3-element table: directory, filename, & full path lengths
    loaded,          -- flagged once the initial load has taken place
    pending,         -- number of files pending write completion (max 2)
    queue,           -- cache_write queue in case of multiple write requests
    writing,         -- file writing object returned by the write command
    subs_off,        -- whether subs were disabled on write due to incompatibility
    quitsec,         -- user specified quit time in seconds
    quit_timer,      -- player quit timer set according to quitsec
    forced_title,    -- unexpanded user set title
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
    prior,           -- cache duration prior to staging the seamless reload mechanism
    seekend,         -- seekable cache end timestamp
    part,            -- approx. end time of last piece / start time of next piece
    switch,          -- request to observe track switches and seeking
    use,             -- use cache_time instead of seekend for initial piece
    id,              -- number of times the packet tracking event has fired
    packets,         -- table of periodic timers indexed by cache id stamps
}

local track = {
    vid,             -- video track id
    aid,             -- audio track id
    sid,             -- subtitle track id
    restart,         -- hostchange interval where subsequent reloads are immediate
    suspend,         -- suspension interval on track-list changes
}

local update = {}       -- option update functions, {mode, label, on_demand} ⊈ update
local segments = {}     -- chapter segments set for writing
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
local reset
local get_seekable_cache
local automatic
local autoquit
local packet_events
local observe_cache
local observe_tracks

local MAX_PATH_LENGTH = 259
local UNICODE = "[%z\1-\127\194-\244][\128-\191]*"

local function convert_time(value)
    local H, M, S = value:match("^(%d+):([0-5]%d):([0-5]%d)$")
    if H then
        return H*3600 + M*60 + S
    end
end

local function enabled(option)
    return string.len(option) > 0
end

local function throw(s, ...)
    local try = function(...) msg.error(s:format(...)) end
    if not pcall(try, ...) then
        -- catch and explicitly cast in case of Lua 5.1 which doesn't coerce
        -- non-string types while formatting with the string specifier
        local args = pack(...)
        for i = 1, args.n do
            args[i] = tostring(args[i])
        end
        try(unpack(args, 1, args.n))
    end
end

local function deprecate()
    local warn = false
    local options = {"force_extension", "force_title"}
    for _, option in next, options do
        if opts[option] == "no" then
            opts[option] = ""
            warn = true
        end
    end
    if warn then
        msg.warn('Deprecation warning: the default setting of "no" has been changed')
        msg.warn('in favour of an empty string for the following options:')
        msg.warn(table.concat(options, ", "))
        msg.warn('Either delete these lines from your streamsave.conf')
        msg.warn('or assign nothing / leave the value blank.')
    end
end

local function show_possible_settings(t)
    msg.warn("Possible settings are:")
    msg.warn(utils.to_string(t))
end

local function validate_opts()
    if not modes[opts.dump_mode] then
        throw("Invalid dump_mode '%s'.", opts.dump_mode)
        show_possible_settings(cycle.modes)
        opts.dump_mode = "ab"
    end
    if not labels[opts.output_label] then
        throw("Invalid output_label '%s'.", opts.output_label)
        show_possible_settings(cycle.labels)
        opts.output_label = "increment"
    end
    if opts.autoend ~= "no" then
        if not cache.part then
            cache.endsec = convert_time(opts.autoend)
        end
        if not convert_time(opts.autoend) then
            throw("Invalid autoend value '%s'. Use HH:MM:SS format.", opts.autoend)
            opts.autoend = "no"
        end
    end
    if opts.quit ~= "no" then
        file.quitsec = convert_time(opts.quit)
        if not file.quitsec then
            throw("Invalid quit value '%s'. Use HH:MM:SS format.", opts.quit)
            opts.quit = "no"
        end
    end
    deprecate()
end

local function append_slash(path)
    if not path:match("[\\/]", -1) then
        return path .. "/"
    else
        return path
    end
end

local function normalize(path)
    -- handle absolute paths
    if path:match("^/") or path:match("^%a:[\\/]") or path:match("^\\\\") then
        return path
    elseif path:match("^\\") then
        -- path relative to cwd root
        -- make sure the drive letter and volume separator are counted
        -- the actual letter doesn't matter as this is only for length measurement
        return "C:" .. path
    end
    -- resolve relative paths
    path = append_slash(utils.getcwd() or "") .. path:gsub("^%.[\\/]", "")
    -- relative paths with ../ are resolved by collapsing
    -- the parent directories iteratively
    local k
    repeat
        path, k = path:gsub("[\\/][^\\/]+[\\/]+%.%.[\\/]", "/", 1)
    until k == 0
    return path
end

local function get_path_length(path)
    return (select(2, path:gsub(UNICODE, "")))
end

function update.save_directory()
    if #opts.save_directory == 0 then
        file.path = opts.save_directory
    else
        -- expand mpv meta paths (e.g. ~~/directory)
        opts.save_directory = append_slash(opts.save_directory)
        file.path = append_slash(mp.command_native {
            "expand-path", opts.save_directory
        })
    end
    file.length = {get_path_length(normalize(file.path))}
end

function update.force_title()
    if enabled(opts.force_title) then
        file.forced_title = opts.force_title
    elseif file.forced_title then
        title_change(_, mp.get_property("media-title"))
    else
        file.forced_title = ""
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

function update.autoend()
    cache.endsec = convert_time(opts.autoend)
    observe_cache()
end

function update.autostart()
    observe_cache()
end

function update.hostchange()
    observe_tracks(opts.hostchange)
end

function update.quit()
    autoquit()
end

function update.piecewise()
    if not opts.piecewise then
        cache.part = 0
    else
        cache.endsec = convert_time(opts.autoend)
    end
end

function update.track_packets()
    packet_events(opts.track_packets)
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

local function push(t, v)
    t[#t + 1] = v
end

-- dump mode switching
local function mode_switch(value)
    if value == "cycle" then
        value = cycle.modes(opts.dump_mode)
    end
    if not modes[value] then
        throw("Invalid dump mode '%s'.", value)
        show_possible_settings(cycle.modes)
        return
    end
    opts.dump_mode = value
    local mode = mode_info[value]
    local append = mode_info.append[value] or ""
    msg.info(mode, "mode" .. append .. ".")
    mp.osd_message("Cache write mode: " .. mode .. append)
end

local function sanitize(title)
    -- guard in case of an empty string
    if #title == 0 then
        return "streamsave"
    end
    -- replacement of reserved characters
    title = title:gsub("[\\/:*?\"<>|]", ".")
    -- avoid outputting dotfiles
    title = title:gsub("^%.", ",")
    return title
end

-- Set the principal part of the file name using the media title
function title_change(_, media_title, req)
    if not media_title then
        file.title = nil
        return
    end
    if enabled(opts.force_title) and not req then
        file.forced_title = opts.force_title
        return
    end
    file.title = sanitize(media_title)
    file.forced_title = ""
    file.oldtitle = nil
end

local function local_mkv(file_format)
    return not mp.get_property_bool("demuxer-via-network") and file_format == "mkv"
end

-- Determine container for standard formats
function container(_, _, req)
    local audio = mp.get_property("audio-codec-name", "none")
    local video = mp.get_property("video-format", "none")
    local file_format = mp.get_property("file-format")
    if not file_format then
        reset()
        observe_tracks()
        file.ext = nil
        return end
    if enabled(opts.force_extension) and not req then
        file.ext = opts.force_extension
        observe_cache()
        observe_tracks()
        return end
    if webm[video] and webm[audio] then
        file.ext = ".webm"
    elseif mp4[video] and mp4[audio] and not local_mkv(file_format) then
        file.ext = ".mp4"
    else
        file.ext = ".mkv"
    end
    observe_cache()
    observe_tracks()
    file.oldext = nil
end

local function cycle_bool_on_missing_arg(arg, opt)
    return arg or (not opt and "yes" or "no")
end

local function throw_on_bool_invalidation(value)
    throw("Invalid input '%s'. Use yes or no.", value)
    mp.osd_message("streamsave: invalid input; use yes or no")
end

local function format_override(ext, force)
    ext = ext or file.ext
    file.oldext = file.oldext or file.ext
    if force == "force" and ext ~= "revert" then
        opts.force_extension = ext
        file.ext = opts.force_extension
        msg.info("file extension globally forced to", file.ext)
        mp.osd_message("streamsave: file extension globally forced to " .. file.ext)
        return
    end
    if ext == "revert" and file.ext == opts.force_extension then
        if force == "force" then
            msg.info("force_extension option reset to default.")
            opts.force_extension = ""
        end
        container(_, _, true)
    elseif ext == "revert" and enabled(opts.force_extension) then
        file.ext = opts.force_extension
    elseif ext == "revert" then
        file.ext = file.oldext
    else
        file.ext = ext
    end
    msg.info("file extension changed to", file.ext)
    mp.osd_message("streamsave: file extension changed to " .. file.ext)
end

local function title_override(title, force)
    title = title or file.title
    file.oldtitle = file.oldtitle or file.title
    if force == "force" and title ~= "revert" then
        opts.force_title = title
        file.forced_title = opts.force_title
        opts.output_label = "increment"
        msg.info("title globally forced to", title)
        mp.osd_message("streamsave: title globally forced to " .. title)
        return
    end
    if title == "revert" and enabled(file.forced_title) then
        if force == "force" then
            msg.info("force_title option reset to default.")
            opts.force_title = ""
        end
        title_change(_, mp.get_property("media-title"), true)
    elseif title == "revert" and enabled(opts.force_title) then
        file.forced_title = opts.force_title
    elseif title == "revert" then
        file.title = file.oldtitle
        file.forced_title = ""
    else
        file.forced_title = title
    end
    title = enabled(file.forced_title) and file.forced_title or file.title
    msg.info("title changed to", title)
    mp.osd_message("streamsave: title changed to " .. title)
end

local function path_override(value)
    value = value or "./"
    file.oldpath = file.oldpath or opts.save_directory
    if value == "revert" then
        opts.save_directory = file.oldpath
    else
        opts.save_directory = value
    end
    update.save_directory()
    msg.info("Output directory changed to", file.path)
    mp.osd_message("streamsave: directory changed to " .. opts.save_directory)
end

local function label_override(value)
    if value == "cycle" then
        value = cycle.labels(opts.output_label)
    end
    if not labels[value] then
        throw("Invalid output label '%s'.", value)
        show_possible_settings(cycle.labels)
        return
    end
    opts.output_label = value
    msg.info("File label changed to", value)
    mp.osd_message("streamsave: label changed to " .. value)
end

local function marks_override(value)
    value = cycle_bool_on_missing_arg(value, opts.range_marks)
    if value == "no" then
        opts.range_marks = false
        if not get_chapters() then
            mp.set_property_native("chapter-list", chapter_list)
        end
        ab_chapters = {}
        msg.info("Range marks disabled.")
        mp.osd_message("streamsave: range marks disabled")
    elseif value == "yes" then
        opts.range_marks = true
        chapter_points()
        msg.info("Range marks enabled.")
        mp.osd_message("streamsave: range marks enabled")
    else
        throw_on_bool_invalidation(value)
    end
end

local function autostart_override(value)
    value = cycle_bool_on_missing_arg(value, opts.autostart)
    if value == "no" then
        opts.autostart = false
        msg.info("Autostart disabled.")
        mp.osd_message("streamsave: autostart disabled")
    elseif value == "yes" then
        opts.autostart = true
        msg.info("Autostart enabled.")
        mp.osd_message("streamsave: autostart enabled")
    else
        throw_on_bool_invalidation(value)
        return
    end
    observe_cache()
end

local function autoend_override(value)
    opts.autoend = value or opts.autoend
    validate_opts()
    cache.endsec = convert_time(opts.autoend)
    observe_cache()
    msg.info("Autoend set to", opts.autoend)
    mp.osd_message("streamsave: autoend set to " .. opts.autoend)
end

local function hostchange_override(value)
    local hostchange = opts.hostchange
    value = cycle_bool_on_missing_arg(value, hostchange)
    if value == "no" then
        opts.hostchange = false
        msg.info("Hostchange disabled.")
        mp.osd_message("streamsave: hostchange disabled")
    elseif value == "yes" then
        opts.hostchange = true
        msg.info("Hostchange enabled.")
        mp.osd_message("streamsave: hostchange enabled")
    elseif value == "on_demand" then
        opts.on_demand = not opts.on_demand
        opts.hostchange = opts.on_demand or opts.hostchange
        local status = opts.on_demand and "enabled" or "disabled"
        msg.info("Hostchange: On Demand", status .. ".")
        mp.osd_message("streamsave: hostchange on_demand " .. status)
    else
        local allowed = "yes, no, or on_demand"
        throw("Invalid input '%s'. Use %s.", value, allowed)
        mp.osd_message("streamsave: invalid input; use " .. allowed)
        return
    end
    if opts.hostchange ~= hostchange then
        observe_tracks(opts.hostchange)
    end
end

local function quit_override(value)
    opts.quit = value or opts.quit
    validate_opts()
    autoquit()
    msg.info("Quit set to", opts.quit)
    mp.osd_message("streamsave: quit set to " .. opts.quit)
end

local function piecewise_override(value)
    value = cycle_bool_on_missing_arg(value, opts.piecewise)
    if value == "no" then
        opts.piecewise = false
        cache.part = 0
        msg.info("Piecewise dumping disabled.")
        mp.osd_message("streamsave: piecewise dumping disabled")
    elseif value == "yes" then
        opts.piecewise = true
        cache.endsec = convert_time(opts.autoend)
        msg.info("Piecewise dumping enabled.")
        mp.osd_message("streamsave: piecewise dumping enabled")
    else
        throw_on_bool_invalidation(value)
    end
end

local function packet_override(value)
    local track_packets = opts.track_packets
    value = cycle_bool_on_missing_arg(value, track_packets)
    if value == "no" then
        opts.track_packets = false
        msg.info("Track packets disabled.")
        mp.osd_message("streamsave: track packets disabled")
    elseif value == "yes" then
        opts.track_packets = true
        msg.info("Track packets enabled.")
        mp.osd_message("streamsave: track packets enabled")
    else
        throw_on_bool_invalidation(value)
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

-- property expansion of user-set titles
local function expand(title)
    if enabled(title) then
        file.title = sanitize(mp.command_native{"expand-text", title})
    end
end

local function check_path_length()
    if file.length[3] > MAX_PATH_LENGTH then
        msg.warn("Path length exceeds", MAX_PATH_LENGTH, "characters")
        msg.warn("and the title cannot be truncated further.")
        msg.warn("The file may fail to write. Use a shorter save_directory path.")
    end
end

local function set_path(label, title)
    local name = title .. label .. file.ext
    file.length[2] = get_path_length(name)
    file.length[3] = file.length[1] + file.length[2]
    return file.path .. name
end

local function set_name(label, title)
    title = title or file.title
    local path = set_path(label, title)
    local path_length = file.length[3]
    local diff = math.min(path_length - MAX_PATH_LENGTH, get_path_length(title) - 1)
    if diff < 1 then
        return path
    else -- truncate
        title = title:gsub(UNICODE:rep(diff) .. "$", "")
        return set_path(label, title)
    end
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

local function get_ranges()
    local cache_state = mp.get_property_native("demuxer-cache-state", {})
    local ranges = cache_state["seekable-ranges"] or {}
    return ranges, cache_state
end

local function get_cache_start()
    local seekable_ranges = get_ranges()
    local seekable_starts = {0}
    for i, range in ipairs(seekable_ranges) do
        seekable_starts[i] = range["start"] or 0
    end
    return math.min(unpack(seekable_starts))
end

local function adjust_initial_chapter(chapter_list)
    if not next(chapter_list) then
        return
    end
    local threshold = 0.1
    local set_zeroth = chapter_list[1]["time"] > threshold
    local cache_start = get_cache_start()
    if not set_zeroth and cache_start <= threshold then
        chapter_list[1]["time"] = cache_start
    end
    return set_zeroth, cache_start
end

local function cache_check(k)
    local seekable_ranges, cache_state = get_ranges()
    local chapter = segments[k]
    local chapt_start, chapt_end = chapter["start"], chapter["end"]
    local chapter_cached = false
    if chapt_end == "no" then
        chapt_end = chapt_start
    end
    for _, range in ipairs(seekable_ranges) do
        if chapt_start >= range["start"] and chapt_end <= range["end"] then
            chapter_cached = true
            break
        end
    end
    if k == 1 and not chapter_cached then
        segments = {}
        msg.error("chapter must be fully cached")
    end
    return chapter_cached, seekable_ranges, cache_state
end

local function fully_cached(k)
    local up_to_end, ranges, cache_state = cache_check(k)
    return cache_state["bof-cached"] and up_to_end and #ranges == 1
end

local function write_chapter(chapter)
    local chapter_list = mp.get_property_native("chapter-list", {})
    local set_zeroth, cache_start = adjust_initial_chapter(chapter_list)
    local zeroth_chapter = chapter == 0 and set_zeroth
    if chapter_list[chapter] or zeroth_chapter then
        segments[1] = {
            ["start"] = zeroth_chapter and cache_start
                        or chapter_list[chapter]["time"],
            ["end"] = chapter_list[chapter + 1]
                      and chapter_list[chapter + 1]["time"]
                      or "no",
            ["title"] = chapter .. ". " .. (not zeroth_chapter
                        and chapter_list[chapter]["title"] or file.title)
        }
        msg.info("Writing chapter", chapter, "....")
        return cache_check(1)
    else
        msg.error("Chapter", chapter, "not found.")
    end
end

local function extract_segments(n, chapter_list)
    local set_zeroth, cache_start = adjust_initial_chapter(chapter_list)
    for i = 1, n - 1 do
        segments[i] = {
            ["start"] = chapter_list[i]["time"],
            ["end"] = chapter_list[i + 1]["time"],
            ["title"] = i .. ". " .. (chapter_list[i]["title"] or file.title)
        }
    end
    if set_zeroth then
        table.insert(segments, 1, {
            ["start"] = cache_start,
            ["end"] = chapter_list[1]["time"],
            ["title"] = "0. " .. file.title
        })
    end
    push(segments, {
        ["start"] = chapter_list[n]["time"],
        ["end"] = "no",
        ["title"] = n .. ". " .. (chapter_list[n]["title"] or file.title)
    })
    local k = #segments
    msg.info("Writing out all", k, "chapters to separate files ....")
    return k
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

local function on_write_finish(mode, file_name)
    return function(success, _, command_error)
        command_error = command_error and msg.error(command_error)
        -- check if file is written
        if utils.file_info(file_name) then
            if success then
                msg.info("Finished writing cache to:", file_name)
            else
                msg.warn("Possibly broken file created at:", file_name)
            end
        else
            msg.error("File not written.")
        end
        if loop.continuous and file.pending == 2 then
            msg.info("Dumping cache continuously to:", file.name)
        end
        file.pending = file.pending - 1
        -- fulfil any write requests now that the pending queue has been serviced
        if next(segments) then
            cache_write("segments", true)
        elseif mode == "segments" then
            mp.osd_message("Cache dumping successfully ended.")
        end
        if file.queue and next(file.queue) and not segments[1] then
            cache_write(unpack(file.queue[1], 1, file.queue[1].n))
            table.remove(file.queue, 1)
        end
        -- re-enable subtitles if they were disabled
        if file.subs_off and file.pending == 0 then
            if not mp.get_property_number("current-tracks/sub/id") then
                mp.set_property_number("sid", track.sid)
            end
            file.subs_off = false
        end
    end
end

function cache_write(mode, quiet, chapter)
    expand(file.forced_title)
    if not (file.title and file.ext) then
        return end
    if file.pending == 2
       or segments[1] and file.pending > 0 and not loop.continuous
    then
        file.queue = file.queue or {}
        -- honor extra write requests when pending queue is full
        -- but limit number of outstanding write requests to be fulfilled
        local queue_size = #file.queue
        if queue_size < 10 then
            file.queue[queue_size + 1] = pack(mode, quiet, chapter)
        end
        return end
    range_flip()
    -- set the output list for the chapter modes
    if mode == "segments" and not segments[1] then
        local chapter_list = mp.get_property_native("chapter-list", {})
        local n = #chapter_list
        if n > 0 then
            local k = extract_segments(n, chapter_list)
            if not fully_cached(k) then
                segments = {}
                msg.error("segments mode: stream must be fully cached")
                return
            end
            quiet = true
            mp.osd_message("Cache dumping started.")
        else
            msg.error("segments mode: stream has no chapters")
            return
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
        file.name = set_name(os.time(), "")
    elseif opts.output_label == "overwrite" then
        file.name = set_name("")
    elseif opts.output_label == "chapter" then
        if segments[1] then
            file.name = set_name("", sanitize(segments[1]["title"]))
        else
            increment_filename()
        end
    end
    check_path_length()
    -- dump cache according to mode
    local file_pos
    file.pending = (file.pending or 0) + 1
    if opts.fallback_write and mode == "ab" and not loop.a and not loop.b then
        mode = "continuous"
    end
    loop.continuous = mode == "continuous"
                      or mode == "ab" and loop.a and not loop.b
                      or segments[1] and segments[1]["end"] == "no"
    if mode == "current" then
        file_pos = mp.get_property_number("playback-time", 0)
    elseif loop.continuous and file.pending == 1 then
        msg.info("Dumping cache continuously to:", file.name)
    end
    -- work around an incompatibility error for certain formats if muxed subs
    -- are selected by toggling the subtitles
    local subs = mp.get_property_native("current-tracks/sub", {})
    local sid = subs["id"]
    if sid and not subs["external"] then
        if file.ext == ".mp4" or subs["codec"] == "webvtt-webm"
        or file.ext == ".webm" and subs["codec"] ~= "webvtt" then
            msg.warn(
                "Output format incompatible with internal subtitle codec.\nSubs",
                "will be disabled while writing and enabled again when finished."
            )
            file.subs_off = mp.set_property("sid", "no")
            track.sid = sid
        end
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
        msg.info("Adjusted range:", loop_range())
    else
        mp.set_property_native("ab-loop-a", loop.a_revert)
        mp.set_property_native("ab-loop-b", loop.b_revert)
        loop.aligned = false
        msg.info("Loop points reverted to:", loop_range())
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
        push(ab_chapters, {
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

function reset()
    if cache.observed or cache.dumped then
        stop()
        mp.unobserve_property(automatic)
        mp.unobserve_property(get_seekable_cache)
        cache.endsec = convert_time(opts.autoend)
        cache.observed = false
    end
    cache.part = 0
    cache.dumped = false
    cache.switch = true
end
reset()

-- reload on demand (hostchange)
local function reload()
    reset()
    observe_tracks()
    msg.warn("Reloading stream due to host change.")
    mp.command("playlist-play-index current")
end

local function stabilize()
    if mp.get_property_number("demuxer-cache-time", 0) > 1500 then
        reload()
    end
end

local function suspend()
    if not track.suspend then
        track.suspend = mp.add_timeout(25, stabilize)
    else
        track.suspend:resume()
    end
end

function get_seekable_cache(prop, range_check)
    -- use the seekable part of the cache for more accurate timestamps
    local seekable_ranges, cache_state = get_ranges()
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
    return math.max(0, unpack(seekable_ends))
end

-- seamlessly reload on inserts (hostchange)
local function seamless(_, cache_state)
    cache_state = cache_state or {}
    local reader = math.abs(cache_state["reader-pts"] or 0)
    local cache_duration = math.abs(cache_state["cache-duration"] or cache.prior)
    -- wait until playback of the loaded cache has practically ended
    -- or there's a timestamp reset / position shift
    if reader >= cache.seekend - 0.25
       or cache.prior - cache_duration > 3000
       or cache_state["underrun"]
    then
        reload()
        track.restart = track.restart or mp.add_timeout(300, function() end)
        track.restart:resume()
    end
end

-- detect stream switches (hostchange)
local function detect()
    local eq = true
    local t = {
        vid = mp.get_property_number("current-tracks/video/id", 0),
        aid = mp.get_property_number("current-tracks/audio/id", 0),
        sid = mp.get_property_number("current-tracks/sub/id", 0)
    }
    for k, v in pairs(t) do
        eq = track[k] == v and eq
        track[k] = v
    end
    -- do not initiate a reload process if the track ids do not match
    -- or the track loading suspension interval is active
    if not eq then
        return
    end
    if track.suspend:is_enabled() then
        stabilize()
        return
    end
    -- bifurcate
    if track.restart and track.restart:is_enabled() then
        track.restart:kill()
        reload()
    elseif opts.on_demand then
        reload()
    else
        -- watch the cache state outside of the interval
        -- and use it to decide when to reload
        reset()
        observe_tracks(false)
        cache.observed = true
        cache.prior = math.abs(mp.get_property_number("demuxer-cache-duration", 4E3))
        cache.seekend = get_seekable_cache()
        mp.observe_property("demuxer-cache-state", "native", seamless)
    end
end

function automatic(_, cache_time)
    if not cache_time then
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
    if cache.dumped and not cache.switch and not cache.endsec then
        mp.unobserve_property(automatic)
        cache.observed = false
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
                msg.info("Quit after", opts.quit)
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
    push(chapter_list, {
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
    local obs_xyz = opts.autostart or cache.endsec
    if not cache.observed and obs_xyz and network then
        cache.dumped = (file.pending or 0) ~= 0
        mp.observe_property("demuxer-cache-time", "number", automatic)
        cache.observed = true
    elseif (cache.observed or cache.dumped) and (not obs_xyz or not network) then
        reset()
    end
end

-- track-list observation switch for runtime changes
function observe_tracks(state)
    if state then
        suspend()
        mp.observe_property("track-list", "native", detect)
    elseif state == false then
        mp.unobserve_property(detect)
        mp.unobserve_property(seamless)
        cache.prior = nil
        local timer = track.restart and track.restart:kill()
    -- reset the state on manual reloads
    elseif cache.prior then
        observe_tracks(false)
        observe_tracks(true)
    elseif opts.hostchange then
        suspend()
    end
end

if opts.hostchange then
    observe_tracks(true)
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
