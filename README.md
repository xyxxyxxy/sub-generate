# sub-generate

A script to scan all video files in a folder recursively and generate missing subtitles in English, using [whisper-asr-webservice](https://github.com/ahmetoner/whisper-asr-webservice).

The subtitles will be placed next to the video as SRT file.

Example of generate subtitle file, next to video file:

```
/Video/MyVideo.mkv
/Video/MyVideo.English [generated].srt
```

Help text:

```bash
Usage: sub-generate.sh [OPTIONS]

Options:
  --start-dir, -sd DIR          Directory to start recursively scanning for videos to process. (default: .)
  --whisper-ip, -wi IP          Set the whisper-asr-webservice IP address. (default: localhost)
  --whisper-port, -wp PORT      Set the whisper-asr-webservice port. (default: 9000)
  --video-formats, -vf FORMATS  Comma-separated list of video formats. (default: mkv,mp4,avi)
  --ignore-dirs, -id DIRS       Comma-separated list of directory names to ignore. (default: backdrops,trailers)
                                Folders containing an .ignore file are also ignored.
  --subtitle-language, -sl LANG Generated subtitle language. (default: English)
                                Used to skip a video, if it already contains embedded subtitles in the target language.
                                Needs to match the mediainfo language output.
  --generated-keyword, -gk WORD Keyword added to the file name of generated subtitle files. (default: [generated])
  --dry-run                     Run without making any changes. (default: false)
  --help                        Display this help message and exit.
```

## Comparison with Bazarr

Bazarr also offers a [Whisper provider](https://wiki.bazarr.media/Additional-Configuration/Whisper-Provider/), using the same backend as this script.

Differences of this script:

- Add a `.English [generated]` suffix to the generated subtitle file name.
  - Enables Emby to display a [custom name](https://emby.media/support/articles/Subtitles.html) for the generated subtitle, indicating to the user it was generated.
    - This is doable in Bazarr with a custom post-processing script, but Bazarr will not find the file anymore after renaming.
- Can handle any video file.
  - Bazarr sees only [Sonarr](https://github.com/Sonarr/Sonarr) and [Radarr](https://github.com/Radarr/Radarr) managed files by design.
  - This script can be run on any folder, including specials, extras and anything else.

## Requirements

1. An instance of [whisper-asr-webservice](https://github.com/ahmetoner/whisper-asr-webservice).
2. `mediainfo` installed on the host to check for existing subtitles and audio language in video.

## Cleanup

The script contains logic to clean up any abandoned generated subtitle file.
A generated subtitle file is considered abandoned, if the video file next to it is no longer present.

The cleanup is performed during the video file scan and any removed file will be logged.

Only subtitle files with the `--generated-keyword` in its file name will be removed.

Be aware that changing the `--generated-keyword` after generating subtitles will put previously generated subtitles out of scope.
In such a case it is recommended to rename the previously generated subtitle files accordingly, replacing the old keyword with the new.

## Notes

Created with the help of AI, using [Microsoft Copilot](https://copilot.microsoft.com).
