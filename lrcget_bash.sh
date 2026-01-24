#!/usr/bin/env bash

GREY="\e[38;5;239m"
LIGHT_GREY="\e[38;5;242m"
GREEN="\e[38;5;2m"
RED="\e[38;5;1m"
DEEP_RED="\e[38;5;88m"
BLUE="\e[38;5;69m"
STEEL_BLUE_DARK="\e[38;5;23m"
DEEP_ORANGE="\e[38;5;208m"
LIGHT_PINK="\e[38;5;177m"
YELLOW="\e[38;5;220m"
NC="\e[0m"

FORCE=false
DEBUG=false
SYNC_ONLY=false
LRCLIB_SERVER="https://lrclib.net"
INPUT_FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
  --force)
    FORCE=true
    shift
    ;;
  --debug)
    DEBUG=true
    shift
    ;;
  --sync-only)
    SYNC_ONLY=true
    shift
    ;;
  --server)
    if [[ -n "$2" && "$2" != -* ]]; then
      LRCLIB_SERVER="${2%/}" # Remove end slash if present
      shift 2
    else
      echo "Error: --server requires a URL value."
      exit 1
    fi
    ;;
  *)
    INPUT_FILE="$1"
    shift
    ;;
  esac
done

if [[ ! "$LRCLIB_SERVER" =~ ^https?:// ]]; then
  echo "Error: Invalid server URL. Must start with http:// or https://"
  exit 1
fi

if [[ -z "$INPUT_FILE" || ! -f "$INPUT_FILE" ]]; then
  echo "Usage: $0 <audio_file> [--force] [--debug] [--sync-only]"
  exit 1
fi

# Only allow audio files
case "${INPUT_FILE##*.}" in
mp3 | flac | wav | m4a | aac | ogg | opus | wma) ;;
*)
  echo "Error: Only audio files allowed (mp3, m4a, aac, ogg, opus and wma)"
  exit 1
  ;;
esac

METADATA=$(ffprobe -v quiet -print_format flat -show_format -show_streams "$INPUT_FILE")

BASENAME="${INPUT_FILE%.*}"
STATUS="???"
STATUS_COLOR="$NC"
IS_LYRIC_ALREADY_THERE=false

# Check for embedded lyrics, existing .lrc or .txt files next to $INPUT_FILE and skip if present
if ! $FORCE && (echo "$METADATA" | grep -qiE "\.tags\.(lyrics|uslt|unsyncedlyrics|sylt|txt)=" ||
  [[ -f "${BASENAME}.lrc" || -f "${BASENAME}.txt" ]]); then
  STATUS="ESC" # Skip
  STATUS_COLOR="$YELLOW"
  IS_LYRIC_ALREADY_THERE=true
fi

# Extract tags
extract_tag() {
  echo "$METADATA" | grep -im1 "\.tags\.$1=" | cut -d'=' -f2- | tr -d '"'
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

if ! "$IS_LYRIC_ALREADY_THERE"; then
  # Cleanup string
  uri() { jq -rn --arg x "$1" '$x|@uri'; }
  URI_TRACK_TITLE=$(uri "$API_TRACK_TITLE")
  URI_TRACK_ARTIST=$(uri "$TRACK_ARTIST")
  URI_TRACK_ALBUM=$(uri "$TRACK_ALBUM")

  API_GET_URL="${LRCLIB_SERVER}/api/get?track_name=${URI_TRACK_TITLE}&artist_name=${URI_TRACK_ARTIST}&album_name=${URI_TRACK_ALBUM}&duration=${TRACK_SECONDS}"
  API_GET_RESPONSE=$(curl -s -A "lrcget_bash (https://github.com/dpi0/lrcget_bash)" --retry 3 --retry-delay 1 --max-time 30 "$API_GET_URL")

  SYNCED_LYRICS=$(echo "$API_GET_RESPONSE" | jq -r '.syncedLyrics // empty')
  PLAIN_LYRICS=$(echo "$API_GET_RESPONSE" | jq -r '.plainLyrics // empty')
  HTTP_CODE=$(echo "$API_GET_RESPONSE" | jq -r '.statusCode // 200')
  TRACK_NAME=$(echo "$API_GET_RESPONSE" | jq -r '.name // empty')
  IS_INSTRUMENTAL=$(echo "$API_GET_RESPONSE" | jq -r '.instrumental // false')

  if [[ -n "$SYNCED_LYRICS" ]]; then
    LRC_FILE="${BASENAME}.lrc"
    echo -e "$SYNCED_LYRICS" >"$LRC_FILE"
    STATUS="SYN"
    STATUS_COLOR="$GREEN"
  elif [[ "$IS_INSTRUMENTAL" == true ]]; then
    STATUS="INS"
    STATUS_COLOR="$DEEP_ORANGE"
  elif [[ "$SYNC_ONLY" == true ]]; then
    API_SEARCH_URL="${LRCLIB_SERVER}/api/search?track_name=${URI_TRACK_TITLE}&artist_name=${URI_TRACK_ARTIST}"
    SEARCH_RESPONSE=$(curl -s -A "lrcget_bash (https://github.com/dpi0/lrcget_bash)" --retry 3 --retry-delay 1 --max-time 30 "$API_SEARCH_URL")

    # 1. Select items where syncedLyrics != null
    # 2. Sort by difference in duration (squared to get absolute distance, thanks to Gemini)
    # 3. Pick the top one
    API_SEARCH_RESPONSE=$(echo "$SEARCH_RESPONSE" | jq --arg d "$TRACK_SECONDS" '
  [ .[] | select(.syncedLyrics != null) ]
  | sort_by((.duration - ($d | tonumber? // 0)) | . * .)
  | .[0] // empty')

    FUZZY_SYNCED_LYRICS=$(echo "$API_SEARCH_RESPONSE" | jq -r '.syncedLyrics // empty')

    if [[ -n "$FUZZY_SYNCED_LYRICS" ]]; then
      LRC_FILE="${BASENAME}.lrc"
      echo -e "$FUZZY_SYNCED_LYRICS" >"$LRC_FILE"
      STATUS="SYN"
      STATUS_COLOR="$GREEN"
    else
      STATUS="404" # No synced lyrics found even after fuzzy search
      STATUS_COLOR="$DEEP_RED"
    fi
  elif [[ "$HTTP_CODE" == "404" || "$TRACK_NAME" == "TrackNotFound" ]]; then
    STATUS="404" # 404 Not Found OR 'name' = 'TrackNotFound'
    STATUS_COLOR="$DEEP_RED"
  elif [[ -n "$PLAIN_LYRICS" ]]; then
    TXT_FILE="${BASENAME}.txt"
    echo -e "$PLAIN_LYRICS" >"$TXT_FILE"
    STATUS="TXT"
    STATUS_COLOR="$LIGHT_PINK"
  else
    STATUS="ERR" # Any other HTTP Error
    STATUS_COLOR="$RED"
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

if $DEBUG; then
  echo -e "${LIGHT_GREY}REQUEST CMD:${NC}${GREY} curl -s -A \"lrcget_bash (https://github.com/dpi0/lrcget_bash)\" --retry 3 --retry-delay 1 --max-time 30 \"$API_GET_URL\"${NC}"

  API_GET_COMPACT_RESPONSE=$(
    echo "$API_GET_RESPONSE" | jq '
      .plainLyrics = (if .plainLyrics then "<HIDDEN>" else .plainLyrics end)
      | .syncedLyrics = (if .syncedLyrics then "<HIDDEN>" else .syncedLyrics end)
    '
  )

  echo -e "${LIGHT_GREY}RESPONSE JSON:${NC} ${GREY}$API_GET_COMPACT_RESPONSE${NC}"

  if [[ -n "$API_SEARCH_URL" ]]; then
    echo -e "${LIGHT_GREY}/API/SEARCH REQUEST CMD:${NC}${GREY} curl -s -A \"lrcget_bash (https://github.com/dpi0/lrcget_bash)\" --retry 3 --retry-delay 1 --max-time 30 \"$API_SEARCH_URL\"${NC}"
    if [[ -n "$API_SEARCH_RESPONSE" ]]; then
      API_SEARCH_COMPACT_RESPONSE=$(
        echo "$API_SEARCH_RESPONSE" | jq '
        .plainLyrics = (if .plainLyrics then "<HIDDEN>" else .plainLyrics end)
        | .syncedLyrics = (if .syncedLyrics then "<HIDDEN>" else .syncedLyrics end)
      '
      )
      echo -e "${LIGHT_GREY}/API/SEARCH RESPONSE JSON:${NC} ${GREY}$API_SEARCH_COMPACT_RESPONSE${NC}"
    else
      echo -e "${LIGHT_GREY}/API/SEARCH RESPONSE JSON:${NC} ${DEEP_RED}<no matching result>${NC}"
    fi
  fi
fi
