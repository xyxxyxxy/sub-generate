#!/bin/bash

# Default values for variables
START_DIR="."
WHISPER_IP="localhost"
WHISPER_PORT="9000"
VIDEO_FORMATS=("mkv" "mp4" "avi")
IGNORE_DIRS=("backdrops" "trailers")
SUBTITLE_LANGUAGE="English"
GENERATED_KEYWORD="[generated]"
DRY_RUN=false

show_help() {
    echo "Usage: $(basename "$0") [OPTIONS]"
    echo
    echo "Options:"
    echo "  --start-dir, -sd DIR          Directory to start recursively scanning for videos to process. (default: $START_DIR)"
    echo "  --whisper-ip, -wi IP          Set the whisper-asr-webservice IP address. (default: $WHISPER_IP)"
    echo "  --whisper-port, -wp PORT      Set the whisper-asr-webservice port. (default: $WHISPER_PORT)"
    echo "  --video-formats, -vf FORMATS  Comma-separated list of video formats. (default: mkv,mp4,avi)"
    echo "  --ignore-dirs, -id DIRS       Comma-separated list of directory names to ignore. (default: backdrops,trailers)"
    echo "                                Folders containing an .ignore file are also ignored."
    echo "  --subtitle-language, -sl LANG Generated subtitle language. (default: $SUBTITLE_LANGUAGE)"
    echo "                                Used to skip a video, if it already contains embedded subtitles in the target language."
    echo "                                Needs to match the mediainfo language output."
    echo "  --generated-keyword, -gk WORD Keyword added to the file name of generated subtitle files. (default: $GENERATED_KEYWORD)"
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
        --help)
            show_help
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
done

if [[ "$SUBTITLE_LANGUAGE" != "English" ]]; then
    echo "Error: Unsupported subtitle language '$SUBTITLE_LANGUAGE'. Only 'English' is currently supported by whisper-asr-webservice."
    exit 1
fi

# Suffix added to the end of the generated subtitle file name.
SUBTITLE_SUFFIX="$SUBTITLE_LANGUAGE $GENERATED_KEYWORD"

# Initialize an empty array to hold the video file paths.
video_files=()

any_error=0

# Function to handle dry run logic
execute_command() {
    local command="$1"
    if [ "$DRY_RUN" = true ]; then
        echo "    DRY_RUN $command"
    else
        echo "    $command"
        # Run command and evaluate exit code.
        if ! eval "$command"; then
            any_error=1
        fi
    fi
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

# Check for subtitle track using mediainfo.
contains_subtitle_language() {
    local file="$1"
    local response

    # Run mediainfo and capture the response
    response=$(mediainfo "$file")

    # Check if the response is empty
    if [[ -z "$response" ]]; then
        echo "Warn: mediainfo response was empty."
        return 1
    fi

    # Process the mediainfo response to find the subtitle language
    echo "$response" | awk '/Text/,/Language/ { if ($1 == "Language" && $3 == "'"$SUBTITLE_LANGUAGE"'") found=1 } END { exit !found }'
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
                    # Check generated subtitle is already present for this video.
                    local subtitle_file="${item%.*}.$SUBTITLE_SUFFIX.srt"
                    if [[ ! -f "$subtitle_file" ]]; then
                        # Check if video already has subtitles in the target language embedded.
                        if ! contains_subtitle_language "$item"; then
                            echo "Schedule subtitle generation for $item"
                            video_files+=("$item")
                        fi
                    fi
                fi
            done
        fi
    done
}

# Any API error returned will be written as output in the generated subtitle file.
# We check here for such errors to catch them and remove the generated file.
check_output_file() {
    # Check for "Internal Server Error" response.
    if [[ $(<"$output_file") == "Internal Server Error" ]]; then
        echo "Error: whisper-asr-webservice returned 'Internal Server Error'. Check server logs for more info."
        execute_command "rm \"$output_file\""
        any_error=1
        return
    fi

    # Check if output starts with '{'.
    # This indicates a JSON response, instead of SRT.
    if head -n 1 "$output_file" | grep -q '^{'; then
        echo "Error: whisper-asr-webservice returned:"
        cat "$output_file"
        execute_command "rm \"$output_file\""
        any_error=1
        return
    fi

    # Note: The generated file being empty is no error.
    #       The video might not conatin speach at all.
    #       The empty file will prevent the script from
    #       repeatidly generating subtitles for that video.
}

# Returns language code for first audio track of file.
# See: https://github.com/openai/whisper/blob/main/whisper/tokenizer.py
# Returns 'null' if no language metadata is available.
get_audio_language_code() {
    local file=$1
    mediainfo --Output=JSON "$file" | jq -r '.media.track[]? | select(.["@type"] == "Audio") | .Language?' | head -n 1
}

generate_subtitles() {
    local file="$1"
    local output_file="${file%.*}.$SUBTITLE_SUFFIX.srt"
    local language=$(get_audio_language_code "$file")

    # Skip files without clear language.
    if [ -z "$language" ] || [ "$language" == "null" ]; then
        echo "Warn: Skipping. Failed to detect audio language of first audio track."
        return
    fi

    echo "Language: $language"

    # Send the audio MKV file to Whisper and receive STR subtitles.
    execute_command "curl --no-progress-meter --request POST --header \"content-type: multipart/form-data\" --form \"audio_file=@$file\" \"http://${WHISPER_IP}:${WHISPER_PORT}/asr?task=translate&language=${language}&output=srt\" --output \"$output_file\""

    # Skip file check on dry run, since no file was created.
    if [ "$DRY_RUN" = true ]; then
        return
    fi

    # Check file, if it was created successfully.
    if [[ -f "$output_file" ]]; then
        check_output_file "$output_file"
    else
        # Making sure the file is generated.
        echo "Error: Failed to generate subtitle."
        any_error=1
    fi
}

# Start scanning from the provided directory.
echo "Scanning directory $START_DIR"
scan_directory "$START_DIR"

# Generate subtitles for all collected videos and log progress.
for i in "${!video_files[@]}"; do
    echo "Processing file $((i + 1)) of ${#video_files[@]}: ${video_files[$i]}"
    generate_subtitles "${video_files[$i]}"
done

if [ $any_error -eq 0 ]; then
    echo "Done."
    exit 0
else
    echo "Completed with errors. See above."
    exit 1
fi
