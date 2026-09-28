#!/bin/bash
# Tests for tdarr_autoscan.sh. Runs the script against a fake `curl` on PATH
# that records every request instead of sending it.
#
# Usage: bash test/tdarr_autoscan_test.sh   (needs python for JSON checks)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../tdarr_autoscan.sh"
PYTHON="$(command -v python3 || command -v python)"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"

# Fake curl: appends one record per call to $CURL_LOG:
#   URL<TAB><url>
#   HDR<TAB><header>        (one per --header)
#   DATA<TAB><payload>
#   END
# Exits 22 (curl --fail HTTP error) when the payload contains $FAKE_CURL_FAIL_MATCH.
cat > "$WORK/bin/curl" <<'FAKE'
#!/bin/bash
url="" data=""
hdrs=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --url) url="$2"; shift 2 ;;
    --header|-H) hdrs+=("$2"); shift 2 ;;
    --data|-d) data="$2"; shift 2 ;;
    --request|-X) shift 2 ;;
    *) shift ;;
  esac
done
{
  printf 'URL\t%s\n' "$url"
  for h in "${hdrs[@]+"${hdrs[@]}"}"; do printf 'HDR\t%s\n' "$h"; done
  printf 'DATA\t%s\n' "$data"
  echo END
} >> "$CURL_LOG"
if [[ -n "${FAKE_CURL_FAIL_MATCH:-}" && "$data" == *"$FAKE_CURL_FAIL_MATCH"* ]]; then
  echo "curl: (22) The requested URL returned error: 500" >&2
  exit 22
fi
exit 0
FAKE
chmod +x "$WORK/bin/curl"

PASS=0 FAIL=0
ok()   { PASS=$((PASS + 1)); echo "ok   - $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL - $1"; [[ -n "${2:-}" ]] && printf '       %s\n' "$2"; }

# run_script VAR=VALUE... : runs the script with a clean env plus the given vars.
# Sets RC, OUT, ERR; requests land in $CURL_LOG.
run_script() {
  CURL_LOG="$WORK/curl.log"; : > "$CURL_LOG"
  env -i PATH="$WORK/bin:$PATH" CURL_LOG="$CURL_LOG" \
    TDARR_URL="http://Tdarr:8266" TDARR_DB_ID="LIBID" \
    "$@" bash "$SCRIPT" > "$WORK/out" 2> "$WORK/err"
  RC=$?
  OUT="$(cat "$WORK/out")"; ERR="$(cat "$WORK/err")"
}

# calls: prints "<endpoint> <mode-or-scan> <path>" per request, in order.
calls() {
  _calls | tr -d '\r'
}
_calls() {
  "$PYTHON" - "$CURL_LOG" <<'PY'
import json, sys
url = data = None
for line in open(sys.argv[1], encoding="utf-8").read().splitlines():
    if line.startswith("URL\t"): url = line[4:]
    elif line.startswith("DATA\t"): data = line[5:]
    elif line == "END":
        d = json.loads(data)["data"]
        ep = url.rsplit("/", 1)[-1]
        if ep == "cruddb":
            print(f"cruddb {d['mode']} {d['collection']} {d['docID']}")
        else:
            sc = d["scanConfig"]
            print(f"scan-files {sc['mode']} {sc['dbID']} {'|'.join(sc['arrayOrPath'])}")
PY
}

expect_calls() { # name expected
  local got; got="$(calls 2>&1)"
  if [[ "$got" == "$2" ]]; then ok "$1"; else fail "$1" "expected: $(printf '%q' "$2")  got: $(printf '%q' "$got")"; fi
}
expect_rc() { if [[ "$RC" == "$2" ]]; then ok "$1"; else fail "$1" "expected rc $2, got $RC (stderr: $ERR)"; fi; }
expect_no_stderr() { if [[ -z "$ERR" ]]; then ok "$1"; else fail "$1" "stderr: $ERR"; fi; }

MOVIES_T='^/movies|/media/movies'
TV_T='^/tv|/media/tv'

# --- plain import (existing behaviour) ------------------------------------
run_script radarr_eventtype=Download radarr_isupgrade=False \
  radarr_moviefile_path="/movies/A (2020)/A.mkv" TDARR_PATH_TRANSLATE="$MOVIES_T"
expect_rc "radarr import: exit 0" 0
expect_calls "radarr import: scans the new file only" \
  "scan-files scanFolderWatcher LIBID /media/movies/A (2020)/A.mkv"

# --- upgrade: remove replaced records, then scan new file -----------------
run_script radarr_eventtype=Download radarr_isupgrade=True \
  radarr_moviefile_path="/movies/K (2025)/K - [Bluray-1080p][x265].mkv" \
  radarr_deletedpaths="/movies/K (2025)/K - [Bluray-720p][h265].mkv" \
  TDARR_PATH_TRANSLATE="$MOVIES_T"
expect_rc "radarr upgrade: exit 0" 0
expect_calls "radarr upgrade: removes old record before scanning new file" \
"cruddb removeOne FileJSONDB /media/movies/K (2025)/K - [Bluray-720p][h265].mkv
scan-files scanFolderWatcher LIBID /media/movies/K (2025)/K - [Bluray-1080p][x265].mkv"

run_script sonarr_eventtype=Download sonarr_isupgrade=True \
  sonarr_episodefile_path="/tv/S/Season 01/S - S01E01E02 - new.mkv" \
  sonarr_deletedpaths="/tv/S/Season 01/S - S01E01 - old.mkv|/tv/S/Season 01/S - S01E02 - old.mkv" \
  TDARR_PATH_TRANSLATE="$TV_T"
expect_calls "sonarr upgrade: removes every replaced file (pipe-separated)" \
"cruddb removeOne FileJSONDB /media/tv/S/Season 01/S - S01E01 - old.mkv
cruddb removeOne FileJSONDB /media/tv/S/Season 01/S - S01E02 - old.mkv
scan-files scanFolderWatcher LIBID /media/tv/S/Season 01/S - S01E01E02 - new.mkv"

# Same filename: the old record must still be dropped, or the new file
# inherits the old verdict and is never processed.
run_script radarr_eventtype=Download radarr_isupgrade=True \
  radarr_moviefile_path="/movies/G/G.mkv" radarr_deletedpaths="/movies/G/G.mkv" \
  TDARR_PATH_TRANSLATE="$MOVIES_T"
expect_calls "upgrade to the same filename: remove then rescan" \
"cruddb removeOne FileJSONDB /media/movies/G/G.mkv
scan-files scanFolderWatcher LIBID /media/movies/G/G.mkv"

# A failed removal is reported (exit 1) but the new file is still scanned.
run_script radarr_eventtype=Download radarr_isupgrade=True \
  radarr_moviefile_path="/movies/F/new.mkv" radarr_deletedpaths="/movies/F/old.mkv" \
  TDARR_PATH_TRANSLATE="$MOVIES_T" FAKE_CURL_FAIL_MATCH="removeOne"
expect_rc "upgrade with failed removal: exit 1" 1
expect_calls "upgrade with failed removal: still scans the new file" \
"cruddb removeOne FileJSONDB /media/movies/F/old.mkv
scan-files scanFolderWatcher LIBID /media/movies/F/new.mkv"

# --- file-delete events -----------------------------------------------------
run_script radarr_eventtype=MovieFileDelete radarr_moviefile_deletereason=Manual \
  radarr_moviefile_path="$WORK/gone/M.mkv"
expect_rc "manual delete: exit 0" 0
expect_calls "manual delete: removes the record, no scan" \
  "cruddb removeOne FileJSONDB $WORK/gone/M.mkv"

run_script sonarr_eventtype=EpisodeFileDelete sonarr_episodefile_deletereason=MissingFromDisk \
  sonarr_episodefile_path="/tv/S/Season 01/gone.mkv" TDARR_PATH_TRANSLATE="$TV_T"
expect_calls "sonarr missing-from-disk delete: removes translated record" \
  "cruddb removeOne FileJSONDB /media/tv/S/Season 01/gone.mkv"

# Upgrade deletes are handled by the Download event (remove-then-scan in one
# ordered place); acting here could race it and drop the NEW file's record
# when the upgrade kept the same filename.
run_script radarr_eventtype=MovieFileDelete radarr_moviefile_deletereason=Upgrade \
  radarr_moviefile_path="/movies/G/G.mkv" TDARR_PATH_TRANSLATE="$MOVIES_T"
expect_rc "upgrade delete: exit 0" 0
expect_calls "upgrade delete: no requests (Download event handles it)" ""

# File still on disk (e.g. Sonarr unlinking a file it no longer tracks):
# the Tdarr record is still valid, leave it.
touch "$WORK/still-here.mkv"
run_script sonarr_eventtype=EpisodeFileDelete sonarr_episodefile_deletereason=NoLinkedEpisodes \
  sonarr_episodefile_path="$WORK/still-here.mkv"
expect_calls "delete of a file still on disk: no requests" ""

# --- events with nothing to do ------------------------------------------------
run_script radarr_eventtype=MovieAdded
expect_rc "MovieAdded (no file): exit 0" 0
expect_no_stderr "MovieAdded (no file): nothing on stderr (Radarr logs stderr as Error)"
expect_calls "MovieAdded (no file): no requests" ""

# Sonarr's "Import Complete" also reports EventType=Download but sets
# episodefile_paths (plural) instead; per-file Download events cover it.
run_script sonarr_eventtype=Download sonarr_episodefile_paths="/tv/S/a.mkv|/tv/S/b.mkv"
expect_rc "sonarr import-complete: exit 0" 0
expect_no_stderr "sonarr import-complete: nothing on stderr"
expect_calls "sonarr import-complete: no requests" ""

run_script radarr_eventtype=Test
expect_calls "Test event: no requests" ""

run_script
expect_rc "no arr env: exit 0" 0

# --- request shape --------------------------------------------------------------
run_script radarr_eventtype=Download radarr_isupgrade=True \
  radarr_moviefile_path='/movies/Q/Say "Hi" \ now.mkv' radarr_deletedpaths='/movies/Q/Say "Hi" \ old.mkv' \
  TDARR_PATH_TRANSLATE="$MOVIES_T"
expect_calls "quotes and backslashes in paths are JSON-escaped" \
"cruddb removeOne FileJSONDB /media/movies/Q/Say \"Hi\" \\ old.mkv
scan-files scanFolderWatcher LIBID /media/movies/Q/Say \"Hi\" \\ now.mkv"

if grep -q $'^HDR\tx-api-key' "$CURL_LOG"; then fail "no TDARR_API_KEY: no x-api-key header"; else ok "no TDARR_API_KEY: no x-api-key header"; fi

run_script radarr_eventtype=Download radarr_moviefile_path="/movies/A/A.mkv" TDARR_API_KEY="k123"
if [[ "$(grep -c $'^HDR\tx-api-key: k123$' "$CURL_LOG")" == 1 ]]; then ok "TDARR_API_KEY sent as x-api-key"; else fail "TDARR_API_KEY sent as x-api-key" "$(cat "$CURL_LOG")"; fi
if [[ "$OUT$ERR" == *k123* ]]; then fail "TDARR_API_KEY never printed"; else ok "TDARR_API_KEY never printed"; fi

echo
echo "passed: $PASS  failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
