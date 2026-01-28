#!/usr/bin/env bash

GREY="\e[38;5;239m"
LIGHT_GREY="\e[38;5;242m"
LIGHTER_GREY="\e[38;5;250m"
GREEN="\e[38;5;2m"
DEEP_GREEN="\e[38;5;22m"
RED="\e[38;5;88m"
BLUE="\e[38;5;69m"
STEEL_BLUE_DARK="\e[38;5;23m"
DEEP_ORANGE="\e[38;5;208m"
LIGHT_PINK="\e[38;5;177m"
DEEP_PINK="\e[38;5;96m"
NC="\e[0m"

FORCE=false
DEBUG=false
SYNC_ONLY=false
TEXT_ONLY=false
NO_INSTRUMENTAL=false
CACHED_MODE=false
EMBED=false
LRCLIB_SERVER="https://lrclib.net"
INPUT_FILE=""
INPUT_DIR=""
XARGS_JOBS=8
ARGS=()

show_help() {
  cat <<'EOF'
Fetch lyrics using the LRCLIB API.

Usage:
  lrcget_bash.sh --song <audio_file> [options]
  lrcget_bash.sh --dir <directory>   [options]

Options:
  --song <file>              Process a single audio file
  --dir <directory>          Process all supported audio files in a directory (recursive)

  --force                    Overwrite existing lyrics (use carefully)
  --sync-only                Only fetch synced/timestamped lyrics
  --text-only                Only fetch plain/text lyrics
  --no-instrumental-lrc      Do not generate synced instrumental lyric files
  --cached                   Use cached API results when available (via /api/get-cached)
  --embed                    Embed lyrics into audio file metadata (use carefully)
  --server <url>             Use a custom LRCLIB server (like "http://localhost:3300")
  --debug                    Enable verbose debug output
  --jobs <1-15>              Number of parallel jobs when using --dir (default: 8)
  --help                     Show this help message and exit

Supported audio formats:
  mp3, flac, wav, m4a, aac, ogg, opus, wma

Examples:
  lrcget_bash.sh --song track.mp3
  lrcget_bash.sh --dir Music/ --embed
  lrcget_bash.sh --song song.flac --sync-only --force
EOF
}

die() {
  echo "Error: $1" >&2
  echo "Use --help to see usage information." >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
  --force)
    FORCE=true
    ARGS+=("$1")
    shift
    ;;
  --debug)
    DEBUG=true
    ARGS+=("$1")
    shift
    ;;
  --sync-only)
    SYNC_ONLY=true
    ARGS+=("$1")
    shift
    ;;
  --text-only)
    TEXT_ONLY=true
    ARGS+=("$1")
    shift
    ;;
  --no-instrumental-lrc)
    NO_INSTRUMENTAL=true
    ARGS+=("$1")
    shift
    ;;
  --cached)
    CACHED_MODE=true
    ARGS+=("$1")
    shift
    ;;
  --embed)
    EMBED=true
    ARGS+=("$1")
    shift
    ;;
  --server)
    if [[ -n "$2" && "$2" != -* ]]; then
      LRCLIB_SERVER="${2%/}" # Remove end slash if present
      ARGS+=("$1" "$2")
      shift 2
    else
      die "--server requires a URL value."
    fi
    ;;
  --song)
    if [[ -n "$2" && "$2" != -* ]]; then
      INPUT_FILE="$2"
      shift 2
    else
      die "--song requires a file path."
    fi
    ;;
  --dir)
    if [[ -n "$2" && "$2" != -* ]]; then
      INPUT_DIR="$2"
      shift 2
    else
      die "--dir requires a directory path."
    fi
    ;;
  --jobs)
    if [[ -n "$2" && "$2" =~ ^[0-9]+$ && "$2" -ge 1 && "$2" -le 15 ]]; then
      XARGS_JOBS="$2"
      ARGS+=("$1" "$2")
      shift 2
    else
      die "--jobs requires an integer between 1 and 15."
    fi
    ;;
  --help | -h)
    show_help
    exit 0
    ;;
  *)
    die "Unknown or positional argument '$1' is not allowed. Use --song or --dir."
    ;;
  esac
done

if [[ -n "$INPUT_DIR" ]]; then
  if [[ ! -d "$INPUT_DIR" ]]; then
    die "'$INPUT_DIR' is not a valid directory."
  fi
  find "$INPUT_DIR" -type f \( \
    -name "*.mp3" -o -name "*.flac" -o -name "*.wav" -o -name "*.m4a" \
    -o -name "*.aac" -o -name "*.ogg" -o -name "*.opus" -o -name "*.wma" \
    \) -print0 |
    xargs -0 -P "$XARGS_JOBS" -I {} "$0" "${ARGS[@]}" --song "{}"
  exit 0
fi

REQUIRED_TOOLS="ffprobe curl jq find xargs"

if $EMBED; then
  REQUIRED_TOOLS="$REQUIRED_TOOLS kid3-cli"
  if ! command -v kid3-cli >/dev/null; then
    die "--embed requires kid3-cli to be installed.
If running via the Docker image, kid3-cli is only included in images tagged with :*-embed."
  fi
fi

for tool in $REQUIRED_TOOLS; do
  if ! command -v "$tool" &>/dev/null; then
    echo -e "${RED}Error: Required tool '$tool' is not installed.${NC}" >&2
    echo "Run with --help to see usage information." >&2
    exit 1
  fi
done

if $SYNC_ONLY && $TEXT_ONLY; then
  die "--sync-only and --text-only cannot be used together."
fi

if [[ ! "$LRCLIB_SERVER" =~ ^https?:// ]]; then
  die "Invalid server URL. Must start with http:// or https://"
fi

if [[ -z "$INPUT_FILE" || ! -f "$INPUT_FILE" ]]; then
  die "$0 --song <file> OR --dir <directory> [flags]"
fi

# Only allow audio files
case "${INPUT_FILE##*.}" in
mp3 | flac | wav | m4a | aac | ogg | opus | wma) ;;
*)
  die "Only audio files allowed (mp3, m4a, aac, ogg, opus and wma)"
  ;;
esac

METADATA=$(ffprobe -v quiet -print_format flat -show_format -show_streams "$INPUT_FILE")

BASENAME="${INPUT_FILE%.*}"
STATUS="???"
STATUS_COLOR="$NC"
IS_LYRIC_ALREADY_THERE=false

# Check for embedded lyrics, existing .lrc or .txt files next to $INPUT_FILE and skip if present
if ! $FORCE; then
  # Check for file .lrc
  if [[ -f "${BASENAME}.lrc" ]]; then
    STATUS="SKIP-FILE-SYNC"
    STATUS_COLOR="$DEEP_GREEN"
    IS_LYRIC_ALREADY_THERE=true
  else
    EMBEDDED_TAG_LINE=$(echo "$METADATA" | grep -im1 -E "\.tags\.(lyrics|uslt|unsyncedlyrics|sylt|txt)=")
    EMBEDDED_CONTENT=$(echo "$EMBEDDED_TAG_LINE" | cut -d'=' -f2- | tr -d '"')

    # Check for embedded sync
    if [[ -n "$EMBEDDED_CONTENT" ]] && echo "$EMBEDDED_CONTENT" | grep -qE "\[[0-9]{2}:[0-9]{2}"; then
      STATUS="SKIP-EMBD-SYNC"
      STATUS_COLOR="$DEEP_GREEN"
      IS_LYRIC_ALREADY_THERE=true
    # Check for file .txt
    elif [[ -f "${BASENAME}.txt" ]]; then
      STATUS="SKIP-FILE-TEXT"
      STATUS_COLOR="$DEEP_PINK"
      IS_LYRIC_ALREADY_THERE=true
    # Check for embedded text
    elif [[ -n "$EMBEDDED_CONTENT" ]]; then
      STATUS="SKIP-EMBD-TEXT"
      STATUS_COLOR="$DEEP_PINK"
      IS_LYRIC_ALREADY_THERE=true
    fi
  fi
fi

# Extract tags
extract_tag() {
  echo "$METADATA" | grep -im1 "format\.tags\.$1=" | cut -d'=' -f2- | tr -d '"'
}

get_duration_sec() {
  echo "$METADATA" | grep -m1 'format.duration=' | cut -d'=' -f2 | tr -d '"' | cut -d. -f1
}

TRACK_ALBUM=$(extract_tag "album")
TRACK_ARTIST=$(extract_tag "artist")
TRACK_TITLE=$(extract_tag "title")
TRACK_SECONDS=$(get_duration_sec)

# Use the filename as "TRACK_TITLE" if none found
API_TRACK_TITLE="${TRACK_TITLE:-$(basename "$INPUT_FILE" | sed 's/\.[^.]*$//')}"

# Fix duration to be "N min M sec"
if [[ -n "$TRACK_SECONDS" ]]; then
  TRACK_HUMAN_DURATION="$((TRACK_SECONDS / 60)) min $((TRACK_SECONDS % 60)) sec"
else
  TRACK_HUMAN_DURATION="N/A"
  TRACK_SECONDS=0 # Prevent calc errors by defaulting to 0 if not found
fi

manage_lyric() {
  local content="$1"
  local type="$2" # lrc or txt

  if $EMBED; then
    # Manage special characters in the to be stored lyric metadata, thanks to Gemini
    local escaped_content="${content//\\/\\\\}"
    escaped_content="${escaped_content//\"/\\\"}"

    if kid3-cli -c "set Lyrics \"$escaped_content\"" "$INPUT_FILE" &>/dev/null; then
      if [[ "$type" == "lrc" ]]; then
        STATUS="SAVE-EMBD-SYNC"
        STATUS_COLOR="$GREEN"
      else
        STATUS="SAVE-EMBD-TEXT"
        STATUS_COLOR="$LIGHT_PINK"
      fi
    else
      STATUS="FAIL-SAVE-EMBD"
      STATUS_COLOR="$RED"
    fi
  else
    local target_file="${BASENAME}.${type}"
    echo -e "$content" >"$target_file"
    if [[ "$type" == "lrc" ]]; then
      [[ "$STATUS" != "SAVE-FILE-INST" ]] && STATUS="SAVE-FILE-SYNC"
      STATUS_COLOR="$GREEN"
      [[ "$STATUS" == "SAVE-FILE-INST" ]] && STATUS_COLOR="$DEEP_ORANGE"
    else
      STATUS="SAVE-FILE-TEXT"
      STATUS_COLOR="$LIGHT_PINK"
    fi
  fi
}

if ! "$IS_LYRIC_ALREADY_THERE"; then
  # Cleanup string
  uri() { jq -rn --arg x "$1" '$x|@uri'; }
  URI_TRACK_TITLE=$(uri "$API_TRACK_TITLE")
  URI_TRACK_ARTIST=$(uri "$TRACK_ARTIST")
  URI_TRACK_ALBUM=$(uri "$TRACK_ALBUM")

  API_ENDPOINT="get"
  if $CACHED_MODE; then API_ENDPOINT="get-cached"; fi

  API_GET_URL="${LRCLIB_SERVER}/api/${API_ENDPOINT}?track_name=${URI_TRACK_TITLE}&artist_name=${URI_TRACK_ARTIST}&album_name=${URI_TRACK_ALBUM}&duration=${TRACK_SECONDS}"
  API_GET_RESPONSE=$(curl -s -A "lrcget_bash (https://github.com/dpi0/lrcget_bash)" --retry 3 --retry-delay 1 --max-time 30 "$API_GET_URL")

  SYNCED_LYRICS=$(echo "$API_GET_RESPONSE" | jq -r '.syncedLyrics // empty')
  PLAIN_LYRICS=$(echo "$API_GET_RESPONSE" | jq -r '.plainLyrics // empty')
  IS_INSTRUMENTAL=$(echo "$API_GET_RESPONSE" | jq -r '.instrumental // false')
  MATCH_FOUND=false

  # FIRST TRY: /api/get (or get-cached)
  if [[ "$IS_INSTRUMENTAL" == true ]]; then
    STATUS="SAVE-FILE-INST"
    STATUS_COLOR="$DEEP_ORANGE"
    MATCH_FOUND=true
    if ! $NO_INSTRUMENTAL; then
      manage_lyric "[00:00.00] ♪ Instrumental ♪" "lrc"
      STATUS="SAVE-FILE-INST"
      STATUS_COLOR="$DEEP_ORANGE"
    fi
  elif [[ -n "$SYNCED_LYRICS" && "$TEXT_ONLY" == false ]]; then
    manage_lyric "$SYNCED_LYRICS" "lrc"
    MATCH_FOUND=true
  elif [[ -n "$PLAIN_LYRICS" && "$SYNC_ONLY" == false ]]; then
    manage_lyric "$PLAIN_LYRICS" "txt"
    MATCH_FOUND=true
  fi

  # FALLBACK TRY: /api/search
  if [[ "$MATCH_FOUND" == false ]]; then
    API_SEARCH_URL="${LRCLIB_SERVER}/api/search?track_name=${URI_TRACK_TITLE}&artist_name=${URI_TRACK_ARTIST}"
    SEARCH_RESPONSE=$(curl -s -A "lrcget_bash (https://github.com/dpi0/lrcget_bash)" --retry 3 --retry-delay 1 --max-time 30 "$API_SEARCH_URL")

    # Select best match by selecting the one with the smallest duration difference (thanks to Gemini)
    API_SEARCH_RESPONSE=$(echo "$SEARCH_RESPONSE" | jq --arg d "$TRACK_SECONDS" --argjson s "$SYNC_ONLY" --argjson t "$TEXT_ONLY" '
      [ .[] | select(
          (((.duration // 0) - ($d | tonumber? // 0)) | if . < 0 then -. else . end) <= 20 and
          (.instrumental == true or
          (if $s then .syncedLyrics != null
          elif $t then .plainLyrics != null
          else (.syncedLyrics != null or .plainLyrics != null) end))
      ) ]
      | sort_by(((.duration // 0) - ($d | tonumber? // 0)) | . * .)
      | .[0] // empty')

    FUZZY_SYNCED_LYRICS=$(echo "$API_SEARCH_RESPONSE" | jq -r '.syncedLyrics // empty')
    FUZZY_PLAIN_LYRICS=$(echo "$API_SEARCH_RESPONSE" | jq -r '.plainLyrics // empty')
    FUZZY_IS_INSTRUMENTAL=$(echo "$API_SEARCH_RESPONSE" | jq -r '.instrumental // false')

    if [[ "$FUZZY_IS_INSTRUMENTAL" == true ]]; then
      STATUS="SAVE-FILE-INST"
      STATUS_COLOR="$DEEP_ORANGE"
      if ! $NO_INSTRUMENTAL; then
        manage_lyric "[00:00.00] ♪ Instrumental ♪" "lrc"
        STATUS="SAVE-FILE-INST"
        STATUS_COLOR="$DEEP_ORANGE"
      fi
    elif [[ -n "$FUZZY_SYNCED_LYRICS" && "$TEXT_ONLY" == false ]]; then
      manage_lyric "$FUZZY_SYNCED_LYRICS" "lrc"
    elif [[ -n "$FUZZY_PLAIN_LYRICS" && "$SYNC_ONLY" == false ]]; then
      manage_lyric "$FUZZY_PLAIN_LYRICS" "txt"
    elif [[ $(echo "$SEARCH_RESPONSE" | jq 'length') -gt 0 ]]; then
      STATUS="FAIL-FIND-LYRC" # Didn't find the requested syncedLyrics or plainLyrics (= null)
      STATUS_COLOR="$LIGHTER_GREY"
    else
      STATUS="FAIL-FIND-SONG" # Empty json array
      STATUS_COLOR="$RED"
    fi
  fi
fi

# [TIME] [Y/N] // "File" {Title / Album / Artist / Duration}
printf "${GREY}[%s]${NC} ${STATUS_COLOR}[%s]${NC} ${GREY}//${NC} ${BLUE}\"%s\"${NC} ${STEEL_BLUE_DARK}{%s / %s / %s / %s}${NC}\n" \
  "$(date +%T)" \
  "$STATUS" \
  "$(basename "$INPUT_FILE")" \
  "TITLE: '${TRACK_TITLE:-Unknown}'" \
  "ALBUM: '${TRACK_ALBUM:-Unknown}'" \
  "ARTIST: '${TRACK_ARTIST:-Unknown}'" \
  "$TRACK_HUMAN_DURATION ($TRACK_SECONDS sec)"

if $DEBUG && ! "$IS_LYRIC_ALREADY_THERE"; then
  echo -e "${LIGHT_GREY}REQUEST CMD:${NC}${GREY} curl -s -A \"lrcget_bash (https://github.com/dpi0/lrcget_bash)\" --retry 3 --retry-delay 1 --max-time 30 \"$API_GET_URL\"${NC}"

  API_GET_COMPACT_RESPONSE=$(
    echo "$API_GET_RESPONSE" | jq '
      .plainLyrics = (if .plainLyrics then "<HIDDEN>" else .plainLyrics end)
      | .syncedLyrics = (if .syncedLyrics then "<HIDDEN>" else .syncedLyrics end)
    '
  )

  echo -e "${LIGHT_GREY}RESPONSE JSON:${NC} ${GREY}$API_GET_COMPACT_RESPONSE${NC}"

  if [[ -n "$API_SEARCH_URL" && "$MATCH_FOUND" == false ]]; then
    echo -e "${LIGHT_GREY}/API/SEARCH REQUEST CMD:${NC}${GREY} curl -s -A \"lrcget_bash (https://github.com/dpi0/lrcget_bash)\" --retry 3 --retry-delay 1 --max-time 30 \"$API_SEARCH_URL\"${NC}"
    if [[ -n "$API_SEARCH_RESPONSE" ]]; then
      API_SEARCH_COMPACT_RESPONSE=$(
        echo "$API_SEARCH_RESPONSE" | jq '
        .plainLyrics = (if .plainLyrics then "<HIDDEN>" else .plainLyrics end)
        | .syncedLyrics = (if .syncedLyrics then "<HIDDEN>" else .syncedLyrics end)
      '
      )
      echo -e "${LIGHT_GREY}/API/SEARCH RESPONSE JSON:${NC} ${GREY}$API_SEARCH_COMPACT_RESPONSE${NC}"
    elif [[ $(echo "$SEARCH_RESPONSE" | jq 'length') -eq 0 ]]; then
      echo -e "${LIGHT_GREY}/API/SEARCH RESPONSE JSON:${NC} ${GREY}[] //${NC} ${RED}EMPTY ARRAY${NC}"
    else
      echo -e "${LIGHT_GREY}/API/SEARCH RESPONSE JSON:${NC} ${GREY}{!} //${NC} ${LIGHTER_GREY}NO MATCHING RESULT${NC}"
    fi
  fi
fi
