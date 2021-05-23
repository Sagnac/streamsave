# streamsave.lua

[mpv](https://github.com/mpv-player/mpv) script aimed at saving live streams and clipping online videos without encoding.

Essentially a wrapper around mpv's cache dumping commands, the script adds the following functionality:

* Automatic determination of the output file name and format
* Option to specify the preferred output directory
* Switch between 3 different dump modes:
  * clip mode
  * full/continuous dump
  * write from beginning to current position
* Prevention of file overwrites
* Acceptance of inverted loop ranges, allowing the end point to be set first

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

mpv's `script-message` command can be used to set the dump mode and override the output title or file extension by specifying `streamsave-mode`, `streamsave-title`, and `streamsave-extension` respectively.
If you override the title or file extension the `revert` argument can be used to set it back to the default auto-determined value.

Examples:
```
script-message streamsave-mode continuous
script-message streamsave-title "Example Title"
script-message streamsave-extension .mkv
script-message streamsave-extension revert
```

## Options

Options are specified in `~~/script-opts/streamsave.conf`

Runtime changes to all user options are supported via the `script-opts` property by using mpv's `set` or `change-list` input commands and the `streamsave-` prefix.

----

`save_directory` sets the output file directory. Don't use quote marks or a trailing slash when specifying paths here.

Example: `save_directory=C:/User Directory`

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
Outside of A-B clip mode the first file will not be tagged, only subsequent files with the same title.

There are 3 other choices:

`output_label=timestamp` will append Unix timestamps to the file name.

`output_label=range` will tag the file with the A-B loop range instead using the format HH.MM.SS (e.g. file-\[00.15.00 - 00.20.00\].mkv)

`output_label=overwrite` will not tag the file and will overwrite any existing files with the same name.

## Known issues

Known issues and bugs with the `dump-cache` command:  
* Won't work with some high FPS streams (too many queued packets error)  
* Errors on some videos if you use the default youtube-dl format selection (e.g. dump-cache won't write vp9 + aac with mp4a tags to mkv)

To ensure compatibility it is recommended that you set `--ytdl-format` to:

```
bestvideo[ext=webm]+251/bestvideo[ext=mp4]+(258/256/140)/bestvideo[ext=webm]+(250/249)/best
```

If you want to avoid the queued packet error altogether limit the format to videos with a frame rate less than 60 fps:

```
bestvideo[ext=webm][fps<?60]+251/bestvideo[ext=mp4][fps<?60]+(258/256/140)/bestvideo[ext=webm][fps<?60]+(250/249)/best[fps<?60]/best
```

Note you may still experience issues if the framerate is not known and a high fps stream is selected.
