#!/usr/bin/env bash
# Archive the current VideoLingo output/ into its own timestamped folder so each
# processed video's artifacts are preserved and never overwritten by the next run.
#
# Usage:
#   bash scripts/archive_output.sh [--move] [--label "<name>"] [VIDEOLINGO_DIR]
#
#   --move          Move output/ into the archive instead of copying (frees space;
#                   leaves output/ empty, ready for the next video). Default: copy.
#   --label NAME    Override the derived folder name (default: the downloaded video's
#                   base filename). The timestamp is always appended.
#   VIDEOLINGO_DIR  Optional positional path; otherwise $VIDEOLINGO_DIR or the
#                   default ~/Workdir/Github/VideoLingo is used.
#
# Result: <VIDEOLINGO_DIR>/artifacts/<label>_<YYYYmmdd-HHMMSS>/ containing a copy
# (or move) of everything that was in output/. Prints the archive path on success.

set -uo pipefail

MOVE=0
LABEL=""
POS_DIR=""

while [ $# -gt 0 ]; do
  case "$1" in
    --move)  MOVE=1; shift ;;
    --label) LABEL="${2:-}"; shift 2 ;;
    *)       POS_DIR="$1"; shift ;;
  esac
done

VIDEOLINGO_DIR="${POS_DIR:-${VIDEOLINGO_DIR:-$HOME/Workdir/Github/VideoLingo}}"
OUTPUT_DIR="$VIDEOLINGO_DIR/output"
ARTIFACTS_DIR="$VIDEOLINGO_DIR/artifacts"

if [ ! -d "$OUTPUT_DIR" ]; then
  echo "[archive] No output/ directory at $OUTPUT_DIR — nothing to archive." >&2
  exit 1
fi

# Guard against archiving an empty output/.
if [ -z "$(ls -A "$OUTPUT_DIR" 2>/dev/null)" ]; then
  echo "[archive] output/ is empty — nothing to archive." >&2
  exit 1
fi

# Derive a label from the downloaded media filename recorded in the manifest,
# falling back to the burned video, then to "video".
derive_label() {
  local manifest="$OUTPUT_DIR/input_manifest.json"
  local name=""
  if [ -f "$manifest" ]; then
    # Pull the "path" value and take its basename without extension.
    name="$(sed -n 's/.*"path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$manifest" | head -1)"
    name="$(basename "$name")"
    name="${name%.*}"
  fi
  if [ -z "$name" ] || [ "$name" = "a" ]; then
    # "a.mp4" is the generic HLS output name; prefer the burned video's stem if present.
    if [ -f "$OUTPUT_DIR/output_sub.mp4" ]; then
      name="video"
    fi
  fi
  [ -n "$name" ] && printf '%s' "$name" || printf 'video'
}

if [ -z "$LABEL" ]; then
  LABEL="$(derive_label)"
fi

# Sanitize the label for use as a path segment.
LABEL="$(printf '%s' "$LABEL" | tr '/\\:*?"<>|' '_' | tr -s ' ' '_')"
LABEL="${LABEL:-video}"

TS="$(date +%Y%m%d-%H%M%S)"
DEST="$ARTIFACTS_DIR/${LABEL}_${TS}"

# Never clobber: if the exact dir somehow exists, add a numeric suffix.
suffix=1
BASE_DEST="$DEST"
while [ -e "$DEST" ]; do
  DEST="${BASE_DEST}_${suffix}"
  suffix=$((suffix + 1))
done

mkdir -p "$DEST"

if [ "$MOVE" -eq 1 ]; then
  # Move every entry out of output/ into the archive, leaving output/ empty.
  # Use find to include dotfiles safely.
  ( cd "$OUTPUT_DIR" && find . -mindepth 1 -maxdepth 1 -exec mv {} "$DEST"/ \; )
  echo "[archive] Moved output/ contents to:"
else
  # Copy, preserving structure. -a keeps timestamps/modes; trailing /. copies contents.
  cp -a "$OUTPUT_DIR"/. "$DEST"/
  echo "[archive] Copied output/ contents to:"
fi

echo "$DEST"

# Machine-readable last line for a caller to parse.
echo "ARTIFACT_DIR=$DEST"
