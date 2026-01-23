#!/usr/bin/env bash

GREY="\e[38;5;239m"
GREEN="\e[38;5;2m"
RED="\e[38;5;1m"
BLUE="\e[38;5;69m"
STEEL_BLUE_DARK="\e[38;5;23m"
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

# Fix duration to be "N min M sec"
if [[ -n "$TRACK_SECONDS" ]]; then
  TRACK_HUMAN_DURATION="$((TRACK_SECONDS / 60)) min $((TRACK_SECONDS % 60)) sec"
else
  TRACK_HUMAN_DURATION="N/A"
fi

# Check for all types of embedded lyrics
if echo "$METADATA" | grep -qiE "\.tags\.(lyrics|uslt|unsyncedlyrics|sylt|txt)="; then
  EMB_LYRICS_STATUS="Y"
  STATUS_COLOR="$GREEN"
else
  EMB_LYRICS_STATUS="N"
  STATUS_COLOR="$RED"
fi

# [TIME] [Y/N] // "File" {Title / Album / Artist / Duration}
printf "${GREY}[%s]${NC} ${STATUS_COLOR}[%s]${NC} ${GREY}//${NC} ${BLUE}\"%s\"${NC} ${STEEL_BLUE_DARK}{%s / %s / %s / %s}${NC}\n" \
  "$(date +%T)" \
  "$EMB_LYRICS_STATUS" \
  "$(basename "$INPUT_FILE")" \
  "TITLE: '${TRACK_TITLE:-Unknown}'" \
  "ALBUM: '${TRACK_ALBUM:-Unknown}'" \
  "ARTIST: '${TRACK_ARTIST:-Unknown}'" \
  "$TRACK_HUMAN_DURATION ($TRACK_SECONDS sec)"
