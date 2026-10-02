#!/bin/bash
rsync -avh --progress \
  --exclude='.DS_Store' \
  --exclude='*.tmp' \
  /Users/tmslab03/Desktop/Neuro_Nav_Recordings/ \
  /Volumes/Shared_Drive/Neuro_Nav_App/test


sed -i 's/\r$//' sync_backup.sh


#!/bin/bash

# ---- Config ----
SRC="/Users/tmslab03/Desktop/Neuro_Nav_Recordings/"
DST="/Volumes/Shared_Drive/Neuro_Nav_App/test"
LOG="$HOME/logs/upload_log.txt"
MAX_RETRIES=3
WAIT_SECONDS=5

mkdir -p "$(dirname "$LOG")"

echo "Starting upload..." | tee -a "$LOG"

attempt=1
success=false

while [ $attempt -le $MAX_RETRIES ]; do
    rsync -rtpv --update --partial "$SRC" "$DST" 2>&1 | tee -a "$LOG"
    if [ ${PIPESTATUS[0]} -eq 0 ]; then
        success=true
        break
    fi
    echo "Attempt $attempt failed. Retrying in ${WAIT_SECONDS}s..." | tee -a "$LOG"
    sleep $WAIT_SECONDS
    attempt=$((attempt + 1))
done

if [ "$success" = true ]; then
    echo "Upload complete." | tee -a "$LOG"
else
    echo "Upload FAILED after $MAX_RETRIES attempts." | tee -a "$LOG"
fi