# streamsave.lua

[mpv](https://github.com/mpv-player/mpv) script aimed at saving live streams and clipping online videos without encoding.  
Determines the output file name and format automatically when writing streams to disk from cache using a keybind.  
By default your A-B loop points (default `l` key in mpv) determine the range.

Default keybinds:

`Ctrl+z` dumps cache to disk

`Alt+z` changes dump mode

`Alt+x` aligns loop points to keyframes

It is advisable that you set `--demuxer-max-bytes` and `--demuxer-max-back-bytes` to larger values (e.g. at least 1GiB) in order to have a larger cache.  
If you want to use with local files set `cache=yes` in mpv.conf

## Options

if setting `save_directory` in `~~/script-opts/streamsave.conf` don't use quote marks or a trailing slash.

e.g. `save_directory=C:/User Directory`

mpv double tilde paths `~~/` are also accepted. By default files are dumped in the current directory.

`dump_mode=continuous` in streamsave.conf will use dump-cache, setting the initial timestamp to 0 and the end timestamp to "no".  
Use this mode if you want to dump the entire cache.  
This process will continue as packets are read and until the streams change or the player is closed.  
Under this mode pressing the cache-write keybind again will stop writing the first file and initiate another file starting at 0 and continuing as the cache increases.  
If you want continuous dumping with a different starting point use the default A-B mode instead and only set the first loop point then press the cache-write keybind.  

The `output_label` option in streamsave.conf allows you to choose how the output filename is tagged.  
The default uses a simple step increment for every file output; e.g. file-1.mkv, file-2.mkv, etc.  
If a file with that name already exists in the same directory the increment is replaced with a Unix timestamp in order to prevent overwrites.

There are 3 other choices:

`output_label=timestamp` will append Unix timestamps to all output files regardless and the script will forego the linear increments.

`output_label=range` will tag the file with the A-B loop range instead using the format HH.MM.SS e.g. file-[00.15.00-00.20.00].mkv

`output_label=overwrite` will use the iterated behavior of the default but will overwrite any existing files with the same name.

## Known issues

Known issues and bugs with the `dump-cache` command:  
* Won't work with some high FPS streams (too many queued packets error)  
* Errors on some videos if you use the default youtube-dl format selection
e.g. dump-cache won't write vp9 + aac with mp4a tags to mkv

To ensure compatibility it is recommended that you set `--ytdl-format` to:

`bestvideo[ext=webm]+251/bestvideo[ext=mp4]+(258/256/140)/bestvideo[ext=webm]+(250/249)/best`

If you want to avoid the queued packet error altogether limit the format to videos with a frame rate less than 60 fps:

`bestvideo[ext=webm][fps<?60]+251/bestvideo[ext=mp4][fps<?60]+(258/256/140)/bestvideo[ext=webm][fps<?60]+(250/249)/best[fps<?60]/best`

Note you may still experience issues if the framerate is not known and a high fps stream is selected.
