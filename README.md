# [streamsave.lua](streamsave.lua?raw=true "streamsave.lua")

----

This is a lighter base version of the script which retains the core essential functionality along with a few related auxiliary features. The automation, packet tracking, chapter modes, and extra script-message commands have been stripped here.

This version contains the following functionality:

* Automatic determination of the output file name and format;
* Option to specify the preferred output directory;
* Switch between 5 different dump modes:
  * clip mode;
  * full/continuous dump;
  * write from beginning to current position.
* Prevention of file overwrites;
* Acceptance of inverted loop ranges, allowing the end point to be set first;
* Dynamic chapter indicators on the OSC displaying the clipping interval;

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

## General Options

Options are specified in `~~/script-opts/streamsave.conf`

Runtime updates to all user options are supported via the `script-opts` property by using mpv's `set` or `change-list` input commands and the `streamsave-` prefix.

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

----

The `output_label` option allows you to choose how the output filename is tagged.

The default uses iterated step increments for every file output; i.e. file-1.mkv, file-2.mkv, etc.

There are 3 other choices:

`output_label=timestamp` will use a Unix timestamp for the file name.

`output_label=range` will tag the file with the A-B loop range instead using the format HH.MM.SS (e.g. file-\[00.15.00 - 00.20.00\].mkv)

`output_label=overwrite` will not tag the file and will overwrite any existing files with the same name.

----

The `force_extension` option allows you to force a preferred format and sidestep the automatic detection.

If using this option it is recommended that a highly flexible container is used (e.g. Matroska).<br>
The format is specified as the extension including the dot (e.g. `force_extension=.mkv`).

This option is disabled by default allowing the script to choose between MP4, WebM, and MKV depending on the input format.

----

The `force_title` option will set the title used for the filename. By default the script uses the `media-title`.

This is specified without double quote marks in streamsave.conf, e.g. `force_title=Example Title`.

The `output_label` is still used here and file overwrites are prevented if desired.

----

The `range_marks` option allows the script to set temporary chapters at A-B loop points, resulting in visual guides on the OSC.

If chapters already exist they are stored and cleared whenever any A-B points are set. Once the A-B points are cleared the original chapters are restored. Any chapters added after A-B mode is entered are added to the initial chapter list.

Make sure your build of mpv is up to date or at least includes commit [mpv-player/mpv@`96b246d`](https://github.com/mpv-player/mpv/commit/96b246d9283da99b82800bbd576037d115e3c6e9 "mpv commit 96b246d") so that the seekbar chapter indicators/markers update properly on the OSC.

Unlike the main script at the master branch, this option is enabled by default here.
