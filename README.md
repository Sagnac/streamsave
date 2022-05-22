# [streamsave.lua](https://raw.githubusercontent.com/Sagnac/streamsave/master/streamsave.lua "streamsave.lua")

[mpv](https://github.com/mpv-player/mpv "mpv") script aimed at saving live streams and clipping online videos without encoding.

Essentially a wrapper around mpv's cache dumping commands, the script adds the following functionality:

* Automatic determination of the output file name and format;
* Option to specify the preferred output directory;
* Switch between 3 different dump modes:
  * clip mode;
  * full/continuous dump;
  * write from beginning to current position;
* Prevention of file overwrites;
* Acceptance of inverted loop ranges, allowing the end point to be set first;
* Dynamic chapter indicators on the OSC displaying the clipping interval.

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

## Options

Options are specified in `~~/script-opts/streamsave.conf`

Runtime changes to all user options are supported via the `script-opts` property by using mpv's `set` or `change-list` input commands and the `streamsave-` prefix.

----

`save_directory` sets the output file directory. Don't use quote marks or a trailing slash when specifying paths here.

Example: `save_directory=C:\User Directory`

mpv double tilde paths `~~/` and home path shortcuts `~/` are also accepted. By default files are dumped in the current directory.

----

`dump_mode=continuous` will use dump-cache, setting the initial timestamp to 0 and leaving the end timestamp unset.

Use this mode if you want to dump the entire cache.  
This process will continue as packets are read and until the streams change, the player is closed, or the user presses the stop keybind.

Under this mode pressing the cache-write keybind again will stop writing the first file and initiate another file starting at 0 and continuing as the cache increases.

If you want continuous dumping with a different starting point use the default A-B mode instead and only set the first loop point then press the cache-write keybind.

`dump_mode=current` will dump the cache from timestamp 0 to the current playback position in the file.

----

The `output_label` option allows you to choose how the output filename is tagged.

The default uses iterated step increments for every file output; i.e. file-1.mkv, file-2.mkv, etc.

There are 3 other choices:

`output_label=timestamp` will append Unix timestamps to the file name.

`output_label=range` will tag the file with the A-B loop range instead using the format HH.MM.SS (e.g. file-\[00.15.00 - 00.20.00\].mkv)

`output_label=overwrite` will not tag the file and will overwrite any existing files with the same name.

----

The `force_extension` option allows you to force a preferred format and sidestep the automatic detection.

If using this option it is recommended that a highly flexible container is used (e.g. Matroska).  
The format is specified as the extension including the dot (e.g. `force_extension=.mkv`).

If this option is set, `script-message streamsave-extension revert` will run the automatic determination at runtime; running this command again will reset the extension to what's specified in `force_extension`.

This option is disabled by default allowing the script to choose between MP4, WebM, and MKV depending on the input format.

----

The `force_title` option will set the title used for the filename. By default the script uses the `media-title`.

This is specified without double quote marks in streamsave.conf, e.g. `force_title=Example Title`.

The `output_label` is still used here and file overwrites are prevented if desired. Changing the filename title to the `media-title` is still possible at runtime by using the `revert` argument, as in the `force_extension` example.

----

The `autostart` and `autoend` options are used for automated stream capturing.

Set `autostart=yes` if you want the script to trigger cache writing immediately on stream load.

Set `autoend` to a time format of the form `HH:MM:SS` (e.g. `autoend=01:20:08`) if you want the file writing to stop at that time. The `autoend` feature accepts runtime `script-message` commands under the `streamsave-autoend` name.

----

The `range_marks` option allows the script to set temporary chapters at A-B loop points.

If chapters already exist they are stored and cleared whenever any A-B points are set. Once the A-B points are cleared the original chapters are restored. Any chapters added after A-B mode is entered are added to the initial chapter list.

Make sure your build of mpv is up to date or at least includes commit [mpv-player/mpv@`96b246d`](https://github.com/mpv-player/mpv/commit/96b246d9283da99b82800bbd576037d115e3c6e9 "mpv commit 96b246d") so that the seekbar chapter indicators/markers update properly on the OSC.

This option is disabled by default. Set `range_marks=yes` in streamsave.conf in order to enable it.

----

## Previously known issues

Known issues and bugs with the `dump-cache` command:  
* Won't work with some high FPS streams (too many queued packets error) `[1]`  
* Cache dumping FLAC streams is currently broken `[1]`  
* Errors on some videos if you use the default youtube-dl format selection (e.g. dump-cache won't write vp9 + aac with mp4a tags to mkv) `[2]`

To ensure compatibility it is recommended that you set `--ytdl-format` to:

```
bestvideo[ext=webm]+251/bestvideo[ext=mp4]+(258/256/140)/bestvideo[ext=webm]+(250/249)/best
```

If you want to avoid the queued packet error altogether limit the format to videos with a frame rate less than 60 fps:

```
bestvideo[ext=webm][fps<?60]+251/bestvideo[ext=mp4][fps<?60]+(258/256/140)/bestvideo[ext=webm][fps<?60]+(250/249)/best[fps<?60]/best
```

Note you may still experience issues if the framerate is not known and a high fps stream is selected.

**If you're using an older version of mpv and are receiving incompatible codec_tag errors with live streams (particularly HLS) use [v0.13.2](https://raw.githubusercontent.com/Sagnac/streamsave/b48726e65cd42f980e42fa04b69441ca446b1e43/streamsave.lua "v0.13.2") or force the .ts extension.**

`[1]` Fixed with [mpv-player/mpv#8877](https://github.com/mpv-player/mpv/pull/8877 "mpv pull request #8877")

`[2]` Fixed in [mpv-player/mpv@`643c699`](https://github.com/mpv-player/mpv/commit/643c699f2684987db6073ebe8a6ea76e56c87055 "mpv commit 643c699")
