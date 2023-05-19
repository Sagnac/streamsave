# [streamsave.lua](https://raw.githubusercontent.com/Sagnac/streamsave/master/streamsave.lua "streamsave.lua")

[mpv](https://github.com/mpv-player/mpv "mpv") script aimed at saving live streams and clipping online videos without encoding.

Essentially a wrapper around mpv's cache dumping commands, the script adds the following functionality:

* Automatic determination of the output file name and format;
* Option to specify the preferred output directory;
* Switch between 5 different dump modes:
  * clip mode;
  * full/continuous dump;
  * write from beginning to current position;
  * write current chapter;
  * individually write out all chapters to separate files.
* Prevention of file overwrites;
* Acceptance of inverted loop ranges, allowing the end point to be set first;
* Dynamic chapter indicators on the OSC displaying the clipping interval;
* Option to track HLS packet drops;
* Automated stream saving;
* Workaround for some DAI HLS streams served from .m3u8 where the host changes.

By default the A-B loop points (set using the `l` key in mpv) determine the portion of the cache written to disk.

----

Default keybinds:

`Ctrl+z` dumps cache to disk

`Alt+z` cycles dump mode

`Alt+x` aligns loop points to keyframes (pressing again will restore the initial loop points)

`Ctrl+x` stops continuous dumping

----

It is advisable that you set `--demuxer-max-bytes` and `--demuxer-max-back-bytes` to larger values (e.g. at least 1GiB) in order to have a larger cache.

If you want to use with local files set `cache=yes` in mpv.conf

----

mpv's `script-message` command can be used at runtime to set the dump mode, override the output title or file extension, change the save directory, or switch the output label.
If you override the title, the file extension, or the directory, the `revert` argument can be used to set it back to the default value.

Examples:
```
script-message streamsave-mode continuous
script-message streamsave-title "Example Title"
script-message streamsave-extension .mkv
script-message streamsave-extension revert
script-message streamsave-path ~/streams
script-message streamsave-label range
```

----

## General Options

Options are specified in `~~/script-opts/streamsave.conf`

Runtime changes to all user options are supported via the `script-opts` property by using mpv's `set` or `change-list` input commands and the `streamsave-` prefix.

----

`save_directory` sets the output file directory. Don't use quote marks or a trailing slash when specifying paths here.

Example: `save_directory=C:\User Directory`

mpv double tilde paths `~~/` and home path shortcuts `~/` are also accepted. By default files are dumped in the current directory.

----

`dump_mode=continuous` will use dump-cache, setting the initial timestamp to 0 and leaving the end timestamp unset.

Use this mode if you want to dump the entire cache.<br>
This process will continue as packets are read and until the streams change, the player is closed, or the user presses the stop keybind.

Under this mode pressing the cache-write keybind again will stop writing the first file and initiate another file starting at 0 and continuing as the cache increases.

If you want continuous dumping with a different starting point use the default A-B mode instead and only set the first loop point then press the cache-write keybind.

`dump_mode=current` will dump the cache from timestamp 0 to the current playback position in the file.

`dump_mode=chapter` will write the current chapter to file.

`dump_mode=segments` writes out all chapters to individual files.

Note that for these last two you must have the chapter(s) you wish to output fully cached in whole prior to writing in order for them to be dumped in their entirety as the chapter modes do not utilize continuous writing.

If you wish to output a single chapter using a numerical input instead you can specify it with a command at runtime:
```
script-message streamsave-chapter 7
```

----

The `output_label` option allows you to choose how the output filename is tagged.

The default uses iterated step increments for every file output; i.e. file-1.mkv, file-2.mkv, etc.

There are 4 other choices:

`output_label=timestamp` will append Unix timestamps to the file name.

`output_label=range` will tag the file with the A-B loop range instead using the format HH.MM.SS (e.g. file-\[00.15.00 - 00.20.00\].mkv)

`output_label=overwrite` will not tag the file and will overwrite any existing files with the same name.

`output_label=chapter` uses the chapter title for the file name if using one of the chapter modes.

----

The `force_extension` option allows you to force a preferred format and sidestep the automatic detection.

If using this option it is recommended that a highly flexible container is used (e.g. Matroska).<br>
The format is specified as the extension including the dot (e.g. `force_extension=.mkv`).

If this option is set, `script-message streamsave-extension revert` will run the automatic determination at runtime; running this command again will reset the extension to what's specified in `force_extension`.

This option is disabled by default allowing the script to choose between MP4, WebM, and MKV depending on the input format.

----

The `force_title` option will set the title used for the filename. By default the script uses the `media-title`.

This is specified without double quote marks in streamsave.conf, e.g. `force_title=Example Title`.

The `output_label` is still used here and file overwrites are prevented if desired. Changing the filename title to the `media-title` is still possible at runtime by using the `revert` argument, as in the `force_extension` example.

----

The `range_marks` option allows the script to set temporary chapters at A-B loop points, resulting in visual guides on the OSC.

If chapters already exist they are stored and cleared whenever any A-B points are set. Once the A-B points are cleared the original chapters are restored. Any chapters added after A-B mode is entered are added to the initial chapter list.

Make sure your build of mpv is up to date or at least includes commit [mpv-player/mpv@`96b246d`](https://github.com/mpv-player/mpv/commit/96b246d9283da99b82800bbd576037d115e3c6e9 "mpv commit 96b246d") so that the seekbar chapter indicators/markers update properly on the OSC.

This option is disabled by default; set `range_marks=yes` in streamsave.conf in order to enable it.

You can also enable this feature at runtime using `script-message streamsave-marks yes`.

----

The `track_packets=yes` option adds chapters to positions where packet loss occurs for HLS streams. This gives you a visual sense for where the video is choppy due to low bandwidth or during times of network congestion and makes it easy to preserve continuity and trim around skips which usually cause invalid timestamps.

----

## Automation Options

These features are mostly meant to be used with live streams.

Contrary to general use where you'd typically want a larger cache (clipping streams, saving a full video, writing out everything loaded in memory, etc.), if you're going to be automating any cache writing you probably want a smaller cache size in order to reduce mpv's memory footprint.

This becomes especially important for long streams, which when coupled with constantly writing out the cache to file could slow things down quite a bit and possibly lead to problems. Under automatic saving mode the stream will continuously write to disk immediately so it's not necessary to use a large cache size.

----

The `autostart` and `autoend` options are used for automated stream capturing.

Set `autostart=yes` if you want the script to trigger cache writing immediately on stream load.

Set `autoend` to a time format of the form `HH:MM:SS` (e.g. `autoend=01:20:08`) if you want the file writing to stop after that much of the stream has been cached. The `autoend` feature accepts runtime `script-message` commands under the `streamsave-autoend` name.

----

The `hostchange=yes` option enables an experimental workaround for DAI HLS .m3u8 streams in which the host changes. If enabled this will result in multiple files being output as the stream reloads.

The `autostart` option must also be enabled in order to autosave these types of streams.

This feature accepts associated `script-message` arguments of `yes`, `no`, `on_demand` (see below), and `cycle` which cycles between the first two.

See [`6d5c0e0`](https://github.com/Sagnac/streamsave/commit/6d5c0e04472bd04ad91b5148fb0d9ad5bd9bbb72 "streamsave commit 6d5c0e0") for more info.

The `on_demand` option is a suboption of the hostchange option which, if enabled, triggers reloads immediately across segment switches without waiting until playback has reached the end of the last segment.

This suboption can be toggled at runtime with:
```
script-message streamsave-hostchange on_demand
```

----

The `quit=HH:MM:SS` option will set a one shot quit timer at script load, serving as a replacement for `autoend` when using `hostchange`; once the specified time has elapsed the player will exit.

Running `script-message streamsave-quit HH:MM:SS` at runtime will reset the timer to the specified duration and restart it from the point of input; it can also be disabled entirely by passing `no`.

----

Set `piecewise=yes` if you want to save a stream in parts automatically. This feature will divide a continuous stream into separate output files based on time, which is useful for capturing individual episodic content from a broadcast.

This option must be used with `autoend` which controls the piece size; set `autoend` to the duration preferred for each output file.

This could also be helpful for saving long streams on slow systems. On some slower machines dumping a large cache or writing out a large file can bog things down quite a bit until the writing stops, so this allows you to dump the cache periodically according to the time set in autoend.

This feature also requires `autostart=yes`. Since this is based on start and stop cycles of continuous writing rather than dumping the loaded cache at regular intervals it is not necessary to have a large cache size.
