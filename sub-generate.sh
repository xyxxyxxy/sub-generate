#!/bin/bash

# Default values for variables
START_DIR="."
WHISPER_IP="localhost"
WHISPER_PORT="9000"
VIDEO_FORMATS=("mkv" "mp4" "avi")
IGNORE_DIRS=("backdrops" "trailers")
TEMP_DIR="/tmp"
SUBTITLE_LANGUAGE="English"
GENERATED_KEYWORD="[generated]"
DRY_RUN=false

show_help() {
    echo "Usage: $(basename "$0") [OPTIONS]"
    echo
    echo "Options:"
    echo "  --start-dir, -sd DIR          Start directory. (default: $START_DIR)"
    echo "  --whisper-ip, -wi IP          Set the whisper-asr-webservice IP address. (default: $WHISPER_IP)"
    echo "  --whisper-port, -wp PORT      Set the whisper-asr-webservice port. (default: $WHISPER_PORT)"
    echo "  --video-formats, -vf FORMATS  Comma-separated list of video formats. (default: mkv,mp4,avi)"
    echo "  --ignore-dirs, -id DIRS       Comma-separated list of directory names to ignore. (default: backdrops,trailers)"
    echo "                                Folders containing an .ignore file are also ignored."
    echo "  --temp-dir, -td DIR           Temporary directory for extracted audio files. (default: $TEMP_DIR)"
    echo "  --subtitle-language, -sl LANG Generated subtitle language. (default: $SUBTITLE_LANGUAGE)"
    echo "                                Needs to match the mediainfo language output."
    echo "  --generated-keyword, -gk WORD Keyword used to identify generated subtitle files. (default: $GENERATED_KEYWORD)"
    echo "  --dry-run                     Run without making any changes. (default: $DRY_RUN)"
    echo "  --help                        Display this help message and exit."
    exit 0
}

# Parse named arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --start-dir|-sd)
            START_DIR="$2"
            shift 2
            ;;
        --whisper-ip|-wi)
            WHISPER_IP="$2"
            shift 2
            ;;
        --whisper-port|-wp)
            WHISPER_PORT="$2"
            shift 2
            ;;
        --video-formats|-vf)
            IFS=',' read -r -a VIDEO_FORMATS <<< "$2"
            shift 2
            ;;
        --ignore-dirs|-id)
            IFS=',' read -r -a IGNORE_DIRS <<< "$2"
            shift 2
            ;;
        --temp-dir|-td)
            TEMP_DIR="$2"
            shift 2
            ;;
        --subtitle-language|-sl)
            SUBTITLE_LANGUAGE="$2"
            shift 2
            ;;
        --generated-keyword|-gk)
            GENERATED_KEYWORD="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
done

if [[ "$SUBTITLE_LANGUAGE" != "English" ]]; then
    echo "Error: Unsupported subtitle language '$SUBTITLE_LANGUAGE'. Only 'English' is supported currently by whisper-asr-webservice."
    exit 1
fi

# Suffix added to the end of the generated subtitle file name.
SUBTITLE_SUFFIX="$SUBTITLE_LANGUAGE $GENERATED_KEYWORD"

# Make sure a sub-folder in the temporary directory is used, to avoid any conflicts
# and to be able to delete the whole folder.
TEMP_DIR+="/sub-generate"

# Initialize an empty array to hold the video file paths.
video_files=()

# Function to handle dry run logic
execute_command() {
    local command="$1"
    if [ "$DRY_RUN" = true ]; then
        echo "    DRY_RUN $command"
    else
        eval "$command"
    fi
}

# Remove the temporary directory if it exists.
execute_command "rm --recursive --force \"$TEMP_DIR\""

# Create the temporary directory
execute_command "mkdir --parents \"$TEMP_DIR\""

# Check for subtitle track using mediainfo.
contains_subtitle_language() {
    local file="$1"
    mediainfo "$file" | awk '/Text/,/Language/ { if ($1 == "Language" && $3 == "'"$SUBTITLE_LANGUAGE"'") found=1 } END { exit !found }'
    return $?
}

# Check if the video file has at least one audio track.
has_audio_track() {
    local file="$1"
    ffprobe -v error -show_entries stream=codec_type -of default=noprint_wrappers=1:nokey=1 "$file" | grep -q audio
    return $?
}

# Recursively scan directories for video files to generate subtitles for.
scan_directory() {
    local dir="$1"

    # Check for .ignore file and skip the file exists.
    # This is an Emby convention: https://emby.media/support/articles/Excluding-Files-Folders.html
    if [[ -f "$dir/.ignore" ]]; then
        return
    fi

    # Cleanup abandoned SRTs in every directory.
    cleanup_abandoned_srt "$dir"

    # Iterate over the items in the directory.
    for item in "$dir"/*; do
        if [[ -d "$item" ]]; then
            # Exclude directories in the IGNORE_DIRS array.
            local dirname
            dirname=$(basename "$item")
            if [[ " ${IGNORE_DIRS[@]} " =~ " ${dirname} " ]]; then
                continue
            fi

            # Recursively scan subdirectories.
            scan_directory "$item"
        else
            # Check if the item is a video file in the VIDEO_FORMATS array.
            for format in "${VIDEO_FORMATS[@]}"; do
                if [[ "$item" == *.$format ]]; then
                    # Check if generated subtitle file is already present for this video.
                    local subtitle_file="${item%.*}.$SUBTITLE_SUFFIX.srt"
                    if [[ ! -f "$subtitle_file" ]]; then
                        # Check if the video file contains the specified subtitle language track.
                        if ! contains_subtitle_language "$item" && has_audio_track "$item"; then
                            echo "Schedule subtitle generation for $item"
                            video_files+=("$item")
                        fi
                    fi
                fi
            done
        fi
    done
}

generate_subtitles() {
    local file="$1"

    local audio_file="$TEMP_DIR/$(basename "${file%.*}.audio.mkv")"
    local output_file="${file%.*}.$SUBTITLE_SUFFIX.srt" \

    # Extract the first audio track from the video.
    # Only the first audio track is necessary to generate subtitles.
    # This is done to decrease the file size before sending it to the API.
    execute_command "ffmpeg -loglevel error -i \"$file\" -map 0:a:0 -c:a copy \"$audio_file\""

    # Send the audio MKV file to Whisper and receive STR subtitles.
    execute_command "curl --no-progress-meter --request POST --header \"content-type: multipart/form-data\" --form \"audio_file=@$audio_file\" \"http://${WHISPER_IP}:${WHISPER_PORT}/asr?task=translate&output=srt\" --output \"$output_file\""

    # Remove the temporary audio file.
    execute_command "rm \"$audio_file\""
}

# Clean up abandoned SRT files in a directory.
cleanup_abandoned_srt() {
    local dir="$1"

    # Iterate over generated SRT files in the directory.
    for srt_file in "$dir"/*.srt; do
        # Exit early if the file does not contain the generated keyword.
        [[ "$srt_file" == *"$GENERATED_KEYWORD"* ]] || continue

        local srt_ending=".$SUBTITLE_SUFFIX.srt"
        local base_name="${srt_file::-${#srt_ending}}"
        # Check if any video exists for this generated subtitle file.
        local video_exists=false
        for format in "${VIDEO_FORMATS[@]}"; do
            if [[ -f "${base_name}.$format" ]]; then
                video_exists=true
                break
            fi
        done

        if [[ "$video_exists" = false ]]; then
            echo "Removing abandoned subtitle $srt_file"
            execute_command "rm \"$srt_file\""
        fi
    done
}

# Start scanning from the provided directory.
echo "Scanning directory $(realpath $START_DIR)"
scan_directory "$START_DIR"

# Generate subtitles for all collected videos and log progress.
for i in "${!video_files[@]}"; do
    echo "Processing file $((i + 1)) of ${#video_files[@]}: ${video_files[$i]}"
    generate_subtitles "${video_files[$i]}"
done

# Remove the temporary directory.
execute_command "rm --recursive \"$TEMP_DIR\""

echo "Done"
