#!/bin/bash
set -uo pipefail

# Sonarr/Radarr pass their event details as lowercase <app>_* env vars.
if [[ -n "${sonarr_eventtype:-}" ]]; then
  EVENT_TYPE="${sonarr_eventtype}"
  FILE_PATH="${sonarr_episodefile_path:-}"
  IS_UPGRADE="${sonarr_isupgrade:-}"
  DELETED_PATHS="${sonarr_deletedpaths:-}"
  DELETE_REASON="${sonarr_episodefile_deletereason:-}"
elif [[ -n "${radarr_eventtype:-}" ]]; then
  EVENT_TYPE="${radarr_eventtype}"
  FILE_PATH="${radarr_moviefile_path:-}"
  IS_UPGRADE="${radarr_isupgrade:-}"
  DELETED_PATHS="${radarr_deletedpaths:-}"
  DELETE_REASON="${radarr_moviefile_deletereason:-}"
else
  echo "No recognized *arr eventtype env var set, exiting."
  exit 0
fi

echo "EVENT_TYPE: $EVENT_TYPE"

if [[ "$EVENT_TYPE" == "Test" ]]; then
  echo "EVENT_TYPE: $EVENT_TYPE (Sonarr/Radarr connectivity test) -- not calling Tdarr."
  exit 0
fi

# Translate an *arr container path into Tdarr's view of the same file.
translate_path() {
  if [[ -n "${TDARR_PATH_TRANSLATE:-}" ]]; then
    echo "$1" | sed "s|${TDARR_PATH_TRANSLATE}|"
  else
    echo "$1"
  fi
}

json_escape() {
  local s="${1//\\/\\\\}"
  printf '%s' "${s//\"/\\\"}"
}

# tdarr_post <endpoint> <json payload>
tdarr_post() {
  local auth=()
  if [[ -n "${TDARR_API_KEY:-}" ]]; then
    auth=(--header "x-api-key: ${TDARR_API_KEY}")
  fi
  echo "PAYLOAD: $2"
  # Retry through a Tdarr restart/recreate (connection refused, container name
  # not resolvable, timeouts) so a brief outage doesn't silently lose the scan.
  # Both requests are idempotent. Worst case ~4.5 min, a fast-failing outage ~2 min.
  curl --silent --show-error --fail --request POST \
    --connect-timeout 5 --max-time 30 \
    --retry 4 --retry-delay 30 --retry-all-errors \
    --url "${TDARR_URL}/api/v2/$1" \
    --header 'content-type: application/json' \
    "${auth[@]+"${auth[@]}"}" \
    --data "$2" \
    --location \
    --insecure
}

# Drop Tdarr's record for a file that no longer exists at this path, so a
# stale queued job never runs against it. Removing a record that isn't there
# is a no-op on Tdarr's side.
remove_record() {
  local path
  path=$(translate_path "$1")
  echo "Removing Tdarr record: $path"
  if tdarr_post cruddb "{\"data\": {\"collection\": \"FileJSONDB\", \"mode\": \"removeOne\", \"docID\": \"$(json_escape "$path")\"}}"; then
    echo "Tdarr record removed (or was not present)."
  else
    echo "ERROR: Tdarr removeOne failed for $path (curl exit $?)." >&2
    return 1
  fi
}

scan_file() {
  local path
  path=$(translate_path "$1")
  echo "FILE_PATH: $path"
  if tdarr_post scan-files "{\"data\": {\"scanConfig\": {\"dbID\": \"${TDARR_DB_ID}\", \"arrayOrPath\": [\"$(json_escape "$path")\"], \"mode\": \"scanFolderWatcher\" }}}"; then
    echo "Tdarr accepted the scan request."
  else
    echo "ERROR: Tdarr scan-files request failed (curl exit $?)." >&2
    return 1
  fi
}

rc=0

case "$EVENT_TYPE" in
  MovieFileDelete|EpisodeFileDelete)
    # Upgrades are handled by the Download event below, which removes the old
    # record and scans the new file in order. Acting here too could race it and
    # drop the NEW file's record when the upgrade kept the same filename.
    if [[ "$DELETE_REASON" == "Upgrade" ]]; then
      echo "Delete reason is Upgrade -- handled by the Download event, nothing to do."
    elif [[ -z "$FILE_PATH" ]]; then
      echo "No file path for $EVENT_TYPE, nothing to do."
    elif [[ -e "$FILE_PATH" ]]; then
      echo "File still exists on disk ($DELETE_REASON), keeping its Tdarr record."
    else
      remove_record "$FILE_PATH" || rc=1
    fi
    ;;
  *)
    if [[ "$IS_UPGRADE" == "True" && -n "$DELETED_PATHS" ]]; then
      IFS='|' read -r -a old_paths <<< "$DELETED_PATHS"
      for old in "${old_paths[@]}"; do
        [[ -n "$old" ]] && { remove_record "$old" || rc=1; }
      done
    fi
    # Events without a single file path (MovieAdded, Sonarr's Import Complete,
    # which sets episodefile_paths instead) are expected -- log to stdout, not
    # stderr, since the *arrs log a script's stderr at Error level.
    if [[ -z "$FILE_PATH" ]]; then
      echo "No file path for $EVENT_TYPE, nothing to scan."
    else
      scan_file "$FILE_PATH" || rc=1
    fi
    ;;
esac

exit "$rc"
