--[[ 

streamsave.lua
Version 0.11.0
2021-5-9
https://github.com/Sagnac/streamsave

mpv script aimed at saving live streams and clipping online videos without encoding.
Determines the output file name and format automatically when writing streams to disk from cache using a keybind.
By default your A-B loop points determine the range.

It is advisable that you set --demuxer-max-bytes and --demuxer-max-back-bytes to larger values (e.g. at least 1GiB) in order to have a larger cache.
If you want to use with local files set cache=yes in mpv.conf

Options are specified in ~~/script-opts/streamsave.conf
save_directory sets the output file directory. Don't use quote marks or a trailing slash when specifying paths here.
Example: save_directory=C:/User Directory
mpv double tilde paths ~~/ and home path shortcuts ~/ are also accepted.
By default files are dumped in the current directory.

dump_mode=continuous will use dump-cache, setting the initial timestamp to 0 and the end timestamp to "no".
Use this mode if you want to dump the entire cache.
This process will continue as packets are read and until the streams change or the player is closed.
Under this mode pressing the cache-write keybind again will stop writing the first file and initiate another file starting at 0 and continuing as the cache increases.
If you want continuous dumping with a different starting point use the default A-B mode instead and only set the first loop point then press the cache-write keybind.

The output_label option allows you to choose how the output filename is tagged.
The default uses iterated step increments for every file output; e.g. file-1.mkv, file-2.mkv, etc.
There are 3 other choices:
output_label=timestamp will append Unix timestamps to the file name.
output_label=range will tag the file with the A-B loop range instead using the format HH.MM.SS e.g. file-[00.15.00-00.20.00].mkv
output_label=overwrite will not tag the file and will overwrite any existing files with the same name.

mpv's script-message command can be used to set the dump mode or override the output title or file extension by specifying streamsave-mode, streamsave-title, and streamsave-extension respectively.
If you override the title or file extension, the revert argument can be used to set it back to the default auto-determined value.
Examples:
script-message streamsave-mode continuous
script-message streamsave-title "Example Title"
script-message streamsave-extension .mkv
script-message streamsave-extension revert

Known issues and bugs with the dump-cache command:
Won't work with some high FPS streams (too many queued packets error)
Errors on some videos if you use the default youtube-dl format selection
e.g. dump-cache won't write vp9 + aac with mp4a tags to mkv
To ensure compatibility it is recommended that you set --ytdl-format to:

bestvideo[ext=webm]+251/bestvideo[ext=mp4]+(258/256/140)/bestvideo[ext=webm]+(250/249)/best

If you want to avoid the queued packet error altogether limit the format to videos with a frame rate less than 60 fps:

bestvideo[ext=webm][fps<?60]+251/bestvideo[ext=mp4][fps<?60]+(258/256/140)/bestvideo[ext=webm][fps<?60]+(250/249)/best[fps<?60]/best

Note you may still experience issues if the framerate is not known and a high fps stream is selected.

 ]]

local options = require 'mp.options'
local utils = require 'mp.utils'
local msg = require 'mp.msg'

-- default user options
-- change these in streamsave.conf
local opts = {
    save_directory = [[.]],         -- output file directory
    dump_mode = "ab",               -- clip mode: "ab", full dump: "continuous"
    output_label = "increment",     -- filename tags <range|timestamp|overwrite>
}
options.read_options(opts, "streamsave", function() update_opts() end)

-- for internal use
local file = {
    name,            -- file name
    path,            -- file path
    title,           -- media title
    inc,             -- filename increments
    range,           -- A-B loop range used to tag file
    ext,             -- file extension
    oldtitle,        -- initialized if title is overridden, allows revert
    oldext,          -- initialized if format is overridden, allows revert
}

local a_loop
local b_loop
local a_loop_osd
local b_loop_osd

local function validate_opts()
    if opts.output_label ~= "increment" and
       opts.output_label ~= "range" and
       opts.output_label ~= "timestamp" and
       opts.output_label ~= "overwrite"
    then
        msg.warn("Invalid output_label '" .. opts.output_label .. "'")
        opts.output_label = "increment"
    end
    if opts.dump_mode ~= "ab" and opts.dump_mode ~= "continuous" then
        msg.warn("Invalid dump_mode '" .. opts.dump_mode .. "'")
        opts.dump_mode = "ab"
    end
end

function update_opts()
    -- expand mpv meta paths (e.g. ~~/directory)
    file.path = mp.command_native({"expand-path", opts.save_directory})
    validate_opts()
end
update_opts()

-- dump mode switching
local function mode_switch(value)
    if value == "cycle" then
        if opts.dump_mode == "ab" then
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
    else
        msg.warn("Invalid dump mode '" .. value .. "'")
    end
end

-- Replacement of reserved file name characters on Windows
local function title_change(name, media_title)
    if media_title then
        file.title = media_title:gsub("[\\/:*?\"<>|]", ".")
        file.inc = 1
        file.oldtitle = nil
    end
end
mp.observe_property("media-title", "string", title_change)

-- Determine proper container for compatibility
local function container()
    local file_format = mp.get_property("file-format")
    local video_format = mp.get_property("video-format")
    local audio_format = mp.get_property("audio-codec-name")
    if file_format then
        if string.find(file_format, "mpegts") or
           string.find(file_format, "hls")
        then
            file.ext = ".ts"
        elseif string.find(file_format, "mp4")
            or ((video_format == "h264" or not video_format)
                and (audio_format == "aac" or not audio_format))
        then
            file.ext = ".mp4"
        elseif (video_format == "vp8" or video_format == "vp9"
                or not video_format)
           and (audio_format == "opus" or audio_format == "vorbis"
                or not audio_format)
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
    file.oldext = file.oldext or file.ext
    if ext == "revert" then
        file.ext = file.oldext
    else
        file.ext = ext
    end
    print("file extension changed to " .. file.ext)
    mp.osd_message("streamsave: file extension changed to " .. file.ext)
end

-- Allow user override of title
local function title_override(title)
    file.oldtitle = file.oldtitle or file.title
    if title == "revert" then
        file.title = file.oldtitle
    else
        file.title = title
    end
    print("title changed to " .. file.title)
    mp.osd_message("streamsave: title changed to " .. file.title)
end

local function range_flip()
    a_loop = mp.get_property_number("ab-loop-a")
    b_loop = mp.get_property_number("ab-loop-b")
    if a_loop and b_loop then
        if a_loop > b_loop then
            a_loop, b_loop = b_loop, a_loop
            mp.set_property_number("ab-loop-a", a_loop)
            mp.set_property_number("ab-loop-b", b_loop)
        end
    end
end

local function increment_filename()
    if opts.dump_mode == "continuous" then
        file.name = file.path .. "/" .. file.title .. file.ext
    else
        file.name = file.path .. "/" .. file.title .. -file.inc .. file.ext
    end
    -- check if file exists
    while utils.file_info(file.name) do
        file.inc = file.inc + 1
        file.name = file.path .. "/" .. file.title .. -file.inc .. file.ext
    end
end

local function range_stamp()
    a_loop_osd = mp.get_property_osd("ab-loop-a"):gsub(":", ".")
    b_loop_osd = mp.get_property_osd("ab-loop-b"):gsub(":", ".")
    file.range = "[" .. a_loop_osd .. "-" .. b_loop_osd .. "]"
    file.name = file.path .. "/" .. file.title .. "-" .. file.range .. file.ext
    -- range label is incompatible with full dump, fallback to increment default
    if opts.dump_mode == "continuous" then
        increment_filename()
    end
end

local function cache_write()
    if file.title and file.ext then
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
            range_flip()
            mp.commandv("async", "osd-msg", "ab-loop-dump-cache", file.name)
            if utils.file_info(file.name) then
                file.inc = file.inc + 1
                print("Cache dumped to " .. file.name)
            end
        elseif opts.dump_mode == "continuous" then
            mp.commandv("async", "osd-msg", "dump-cache", "0", "no", file.name)
            if utils.file_info(file.name) then
                print("Cache dumped to " .. file.name)
            end
        end
    end
end

--[[ This command attempts to align the A-B loop points to keyframes.
Use align-cache if you want to know which range will likely be dumped.
Keep in mind this changes the A-B loop points you've set.
This is sometimes inaccurate. ]]
local function align_cache()
    range_flip()
    mp.commandv("osd-msg", "ab-loop-align-cache")
    a_loop_osd = mp.get_property_osd("ab-loop-a")
    b_loop_osd = mp.get_property_osd("ab-loop-b")
    print("Adjusted range: " .. a_loop_osd .. " - " .. b_loop_osd)
end

mp.register_script_message("streamsave-mode", mode_switch)
mp.register_script_message("streamsave-title", title_override)
mp.register_script_message("streamsave-extension", format_override)

mp.add_key_binding("Alt+z", "mode-switch", function() mode_switch("cycle") end)
mp.add_key_binding("Alt+x", "align-cache", align_cache)
mp.add_key_binding("Ctrl+z", "cache-write", cache_write)
