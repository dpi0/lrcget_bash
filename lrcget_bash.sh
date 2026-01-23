#!/usr/bin/env bash

GREY="\e[38;5;239m"
GREEN="\e[38;5;2m"
RED="\e[38;5;1m"
DEEP_RED="\e[38;5;88m"
BLUE="\e[38;5;69m"
STEEL_BLUE_DARK="\e[38;5;23m"
DEEP_ORANGE="\e[38;5;208m"
LIGHT_PINK="\e[38;5;177m"
YELLOW="\e[38;5;220m"
NC="\e[0m"

INPUT_FILE="$1"

if [[ -z "$INPUT_FILE" || ! -f "$INPUT_FILE" ]]; then
  echo "Usage: $0 <audio_file>"
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
if echo "$METADATA" | grep -qiE "\.tags\.(lyrics|uslt|unsyncedlyrics|sylt|txt)=" ||
  [[ -f "${BASENAME}.lrc" || -f "${BASENAME}.txt" ]]; then
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
fi

if ! "$IS_LYRIC_ALREADY_THERE"; then
  # Cleanup string
  uri() { jq -rn --arg x "$1" '$x|@uri'; }
  URI_TRACK_TITLE=$(uri "$API_TRACK_TITLE")
  URI_TRACK_ARTIST=$(uri "$TRACK_ARTIST")
  URI_TRACK_ALBUM=$(uri "$TRACK_ALBUM")

  API_GET_URL="https://lrclib.net/api/get?track_name=${URI_TRACK_TITLE}&artist_name=${URI_TRACK_ARTIST}&album_name=${URI_TRACK_ALBUM}&duration=${TRACK_SECONDS}"
  RESPONSE=$(curl -s -A "lrcget_bash (https://github.com/dpi0/lrcget_bash)" --retry 3 --retry-delay 1 --max-time 30 "$API_GET_URL")

  SYNCED_LYRICS=$(echo "$RESPONSE" | jq -r '.syncedLyrics // empty')
  PLAIN_LYRICS=$(echo "$RESPONSE" | jq -r '.plainLyrics // empty')
  HTTP_CODE=$(echo "$RESPONSE" | jq -r '.statusCode // 200')
  TRACK_NAME=$(echo "$RESPONSE" | jq -r '.name // empty')
  IS_INSTRUMENTAL=$(echo "$RESPONSE" | jq -r '.instrumental // false')

  # Now use the variables instead of re-parsing
  if [[ -n "$SYNCED_LYRICS" ]]; then
    LRC_FILE="${BASENAME}.lrc"
    echo -e "$SYNCED_LYRICS" >"$LRC_FILE"
    STATUS="SYN"
    STATUS_COLOR="$GREEN"
  elif [[ "$IS_INSTRUMENTAL" == true ]]; then
    STATUS="INS"
    STATUS_COLOR="$DEEP_ORANGE"
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
