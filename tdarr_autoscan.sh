#!/bin/bash
set -uo pipefail

if [[ -n "${sonarr_eventtype:-}" ]]; then
  FILE_PATH="${sonarr_episodefile_path:-}"
  EVENT_TYPE="${sonarr_eventtype}"
elif [[ -n "${radarr_eventtype:-}" ]]; then
  FILE_PATH="${radarr_moviefile_path:-}"
  EVENT_TYPE="${radarr_eventtype}"
else
  echo "No recognized *arr eventtype env var set, exiting."
  exit 0
fi

if [[ "$EVENT_TYPE" == "Test" ]]; then
  echo "EVENT_TYPE: $EVENT_TYPE (Sonarr/Radarr connectivity test) -- not calling Tdarr."
  exit 0
fi

if [[ -z "$FILE_PATH" ]]; then
  echo "EVENT_TYPE=$EVENT_TYPE but the file path env var is empty, skipping." >&2
  exit 0
fi

if [[ -n "${TDARR_PATH_TRANSLATE:-}" ]]; then
  FILE_PATH=$(echo "$FILE_PATH" | sed "s|${TDARR_PATH_TRANSLATE}|")
fi

PAYLOAD="{\"data\": {\"scanConfig\": {\"dbID\": \"${TDARR_DB_ID}\", \"arrayOrPath\": [\"$FILE_PATH\"], \"mode\": \"scanFolderWatcher\" }}}"

# debug logs - payload is most important
echo "EVENT_TYPE: $EVENT_TYPE"
echo "FILE_PATH: $FILE_PATH"
echo "TDARR_URL: $TDARR_URL"
echo "PAYLOAD: $PAYLOAD"

if curl --silent --show-error --fail --request POST \
  --url "${TDARR_URL}/api/v2/scan-files" \
  --header 'content-type: application/json' \
  --data "$PAYLOAD" \
  --location \
  --insecure; then
  echo "Tdarr accepted the scan request."
  exit 0
else
  rc=$?
  echo "ERROR: Tdarr scan-files request failed (curl exit $rc)." >&2
  exit 1
fi
