# sub-generate

A script to scan all video files in a folder recursively and generate missing subtitles, using [whisper-asr-webservice](https://github.com/ahmetoner/whisper-asr-webservice).

The subtitles will be placed next to the video as SRT file.

Example of generate subtitle file, next to video file:

```
/Video/MyVideo.mkv
/Video/MyVideo.English [generated].srt
```

Currently supporting English only. See: https://github.com/openai/whisper

## Comparison with Bazarr

Bazarr also offers a [Whisper provider](https://wiki.bazarr.media/Additional-Configuration/Whisper-Provider/), using the same backend as this script.

Differences of this script:

- Add a `.English [generated]` suffix to the generated subtitle file name.
  - Enables Emby to display a [custom name](https://emby.media/support/articles/Subtitles.html) for the generated subtitle, indicating to the user it was generated.
    - This is doable in Bazarr with a custom post-processing script, but Bazarr will not find the file anymore after renaming.
- Can handle any video file.
  - Bazarr sees only [Sonarr](https://github.com/Sonarr/Sonarr) and [Radarr](https://github.com/Radarr/Radarr) files by design.
  - This script can be run on any folder, including specials/extras/anything else.

## Requirements

An instance of [whisper-asr-webservice](https://github.com/ahmetoner/whisper-asr-webservice).

The following commands need to be available on the machine running this script:

- `mediainfo` to check if a video file already has embeded subtitles in the target language.
- `ffmpeg` to extract the audio before sending it to Whisper.
  - `ffprobe` (installed with `ffmpeg`) to check if the video file has an audio track.

## Cleanup

The script contains logic to clean up any abandoned generated subtitle file.
A generated subtitle file is considered abandoned, if the video file next to it is no longer present.

The cleanup is performed during the video file scan and any removed file will be logged.

Only subtitle files with the `--generated-keyword` in its file name will be removed.

Be aware that changing the `--generated-keyword` after generating subtitles will put previously generated subtitles out of scope.
In such a case it is recommended to rename the previously generated subtitle files accordingly, replacing the old keyword with the new.

## Language Detection

No efforts is done to detect the language before sending the audio to Whisper.

## Limiting Runtime

Subtitle generation can take time. With medium settings and hardware a movie-length video can take 10 minutes.
To limit the runtime duration the script can be started using `timeout`, for example to run for maximum 2 hours:

```bash
timeout 2h ./sub-generate.sh
```

If the script is terminated while running, the progress of the currently transcribed file will be lost.
All previously processed files will be fine. The next run continues where left of.

Some temporary files might remain, but will be cleaned up with the next run.

## Notes

Created with the help of AI, using [Microsoft Copilot](https://copilot.microsoft.com).
