#!/usr/bin/env bash
set -euo pipefail

# watch-for-review.sh - Opens a review file and waits for it to be modified
#
# Usage: watch-for-review.sh <file_path>
#
# The script:
# 1. Records the file's current modification time
# 2. Opens the file with the default .md handler
# 3. Polls every 2 seconds until the file is modified
# 4. Exits with 0 once the file has been updated

REVIEW_FILE="${1:?Usage: watch-for-review.sh <file_path>}"
POLL_INTERVAL="${2:-2}"  # seconds between checks, default 2

if [[ ! -f "$REVIEW_FILE" ]]; then
  echo "Error: File not found: $REVIEW_FILE" >&2
  exit 1
fi

# Record initial modification time (macOS stat format)
if [[ "$(uname)" == "Darwin" ]]; then
  initial_mtime=$(stat -f %m "$REVIEW_FILE")
else
  initial_mtime=$(stat -c %Y "$REVIEW_FILE")
fi

# Open with default handler
open "$REVIEW_FILE"

echo "Waiting for review file to be updated..."
echo "  File: $REVIEW_FILE"
echo "  Edit your answers and save to continue."

while true; do
  sleep "$POLL_INTERVAL"

  if [[ "$(uname)" == "Darwin" ]]; then
    current_mtime=$(stat -f %m "$REVIEW_FILE")
  else
    current_mtime=$(stat -c %Y "$REVIEW_FILE")
  fi

  if [[ "$current_mtime" != "$initial_mtime" ]]; then
    echo "Review file updated. Continuing..."
    exit 0
  fi
done
