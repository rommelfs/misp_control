#!/bin/bash

# upgrade all MISP servers stored in config.csv
# config file needed (config.csv)
# fields:
# server_name,API_key
# 2024-03 - 2026 Sascha Rommelfangen, CIRCL, LHC

set -o pipefail

CONFIG="config.csv"
DEBUG=0
USE_COLOR=1
AUTO_MODE=0
CONNECT_TIMEOUT=10
GET_MAX_TIME=120
POST_MAX_TIME=300
GITHUB_MAX_TIME=60
GITHUB_API="https://api.github.com/repos/MISP/MISP"

MANUAL_VERSION_TAG_24=""
MANUAL_VERSION_TAG_25=""
MANUAL_VERSION_RELEASE_24=""
MANUAL_VERSION_RELEASE_25=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --debug) DEBUG=1; shift ;;
    --no-color) USE_COLOR=0; shift ;;
    --auto) AUTO_MODE=1; shift ;;

    --latest-24) MANUAL_VERSION_TAG_24="$2"; shift 2 ;;
    --latest-25) MANUAL_VERSION_TAG_25="$2"; shift 2 ;;
    --release-24) MANUAL_VERSION_RELEASE_24="$2"; shift 2 ;;
    --release-25) MANUAL_VERSION_RELEASE_25="$2"; shift 2 ;;

    --help|-h)
      echo "Usage: $0 [--debug] [--no-color] [--auto] [--latest-24 VERSION] [--latest-25 VERSION] [--release-24 VERSION] [--release-25 VERSION]"
      exit 0
      ;;
    *)
      echo "[!] Unknown argument: $1"
      exit 1
      ;;
  esac
done

[[ ! -t 1 ]] && USE_COLOR=0
[[ -n "${NO_COLOR:-}" ]] && USE_COLOR=0

if [[ "$USE_COLOR" -eq 1 ]]; then
  RED=$'\033[31m'
  GREEN=$'\033[32m'
  YELLOW=$'\033[33m'
  BLUE=$'\033[34m'
  CYAN=$'\033[36m'
  BOLD=$'\033[1m'
  DIM=$'\033[2m'
  RESET=$'\033[0m'
else
  RED=""
  GREEN=""
  YELLOW=""
  BLUE=""
  CYAN=""
  BOLD=""
  DIM=""
  RESET=""
fi

OK="${GREEN}✓ OK${RESET}"
OUTDATED="${YELLOW}↑ OUTDATED${RESET}"
FAILED_TXT="${RED}✗ FAILED${RESET}"
AUTH_TXT="${RED}🔒 AUTH FAILED${RESET}"
UNREACHABLE_TXT="${YELLOW}⚠ UNREACHABLE${RESET}"
DB_LOCKED_TXT="${YELLOW}🔒 DB LOCKED${RESET}"
LATEST_UNKNOWN_TXT="${RED}✗ LATEST UNKNOWN${RESET}"

REQUIRED_CMDS=("curl" "jq" "grep" "sort" "head" "tail" "tr" "sed" "mktemp" "xargs")

for cmd in "${REQUIRED_CMDS[@]}"; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "[!] Required command missing: $cmd"
    exit 1
  }
done

if [ ! -f "$CONFIG" ]; then
  echo "Config file $CONFIG missing. Aborting."
  exit 1
fi

UPDATED=0
SKIPPED=0
FAILED=0
AUTH_FAILED=0
UNREACHABLE=0
DB_LOCKED=0
LATEST_UNKNOWN=0

HOSTS=()
KEYS=()

function hr {
  printf "%s\n" "${DIM}--------------------------------------------------------------------------------${RESET}"
}

function big_hr {
  printf "%s\n" "${DIM}================================================================================${RESET}"
}

function is_json {
  echo "$1" | jq empty >/dev/null 2>&1
}

function github_get {
  local path="$1"
  local url="${GITHUB_API}${path}"
  local tmp_body
  local tmp_err

  tmp_body=$(mktemp)
  tmp_err=$(mktemp)

  local http_code
  http_code=$(curl -sS \
    --connect-timeout "$CONNECT_TIMEOUT" \
    --max-time "$GITHUB_MAX_TIME" \
    -H "Accept: application/vnd.github+json" \
    -H "User-Agent: misp-upgrade-checker" \
    -o "$tmp_body" \
    -w "%{http_code}" \
    "$url" \
    2>"$tmp_err")

  local curl_rc=$?
  local body
  local err
  body=$(cat "$tmp_body")
  err=$(cat "$tmp_err")
  rm -f "$tmp_body" "$tmp_err"

  if [[ $curl_rc -ne 0 ]]; then
    printf '000\ncurl failed with exit code %s\n%s\nURL: %s\n' "$curl_rc" "$err" "$url"
  else
    printf '%s\n%s\n' "$http_code" "$body"
  fi
}

function github_debug {
  local label="$1"
  local http_code="$2"
  local body="$3"

  if [[ "$DEBUG" -eq 1 ]]; then
    echo "${DIM}GitHub debug: $label HTTP $http_code${RESET}" >&2
    if is_json "$body"; then
      echo "$body" | jq . >&2
    else
      echo "$body" >&2
    fi
  fi
}

function get_latest_tag_for_branch {
  local branch="$1"
  local response
  local http_code
  local body

  response=$(github_get "/tags?per_page=100")
  http_code=$(echo "$response" | head -n 1)
  body=$(echo "$response" | tail -n +2)

  if [[ ! "$http_code" =~ ^2 ]] || ! is_json "$body"; then
    github_debug "tags $branch" "$http_code" "$body"
    return
  fi

  echo "$body" | jq -r '
    if type == "array" then
      .[].name
    else
      empty
    end
  ' |
    sed 's/^v//' |
    grep "^${branch}\." |
    sort -V |
    tail -n 1
}

function get_latest_release_for_branch {
  local branch="$1"
  local response
  local http_code
  local body

  response=$(github_get "/releases?per_page=100")
  http_code=$(echo "$response" | head -n 1)
  body=$(echo "$response" | tail -n +2)

  if [[ ! "$http_code" =~ ^2 ]] || ! is_json "$body"; then
    github_debug "releases $branch" "$http_code" "$body"
    return
  fi

  echo "$body" | jq -r '
    if type == "array" then
      .[].tag_name
    else
      empty
    end
  ' |
    sed 's/^v//' |
    grep "^${branch}\." |
    sort -V |
    tail -n 1
}

if [[ -n "$MANUAL_VERSION_TAG_24" ]]; then
  VERSION_TAG_24="$MANUAL_VERSION_TAG_24"
else
  VERSION_TAG_24=$(get_latest_tag_for_branch "2.4")
fi

if [[ -n "$MANUAL_VERSION_TAG_25" ]]; then
  VERSION_TAG_25="$MANUAL_VERSION_TAG_25"
else
  VERSION_TAG_25=$(get_latest_tag_for_branch "2.5")
fi

if [[ -n "$MANUAL_VERSION_RELEASE_24" ]]; then
  VERSION_RELEASE_24="$MANUAL_VERSION_RELEASE_24"
else
  VERSION_RELEASE_24=$(get_latest_release_for_branch "2.4")
fi

if [[ -n "$MANUAL_VERSION_RELEASE_25" ]]; then
  VERSION_RELEASE_25="$MANUAL_VERSION_RELEASE_25"
else
  VERSION_RELEASE_25=$(get_latest_release_for_branch "2.5")
fi

if [[ -z "$VERSION_TAG_24" || -z "$VERSION_TAG_25" ]]; then
  echo "${RED}[!] Could not determine latest MISP tags. Aborting to avoid accidental updates.${RESET}"
  echo "    2.4 latest: ${VERSION_TAG_24:-n/a}"
  echo "    2.5 latest: ${VERSION_TAG_25:-n/a}"
  echo
  echo "Manual fallback example:"
  echo "    $0 --latest-24 2.4.219 --latest-25 2.5.40"
  exit 1
fi

function print_title {
  echo
  echo "${BOLD}${CYAN}MISP Upgrade Checker${RESET}"
  echo "${DIM}Config: $CONFIG${RESET}"

  if [[ "$AUTO_MODE" -eq 1 ]]; then
    echo "${YELLOW}AUTO MODE ENABLED - outdated servers will be updated without confirmation.${RESET}"
  fi

  if [[ -n "$MANUAL_VERSION_TAG_24" || -n "$MANUAL_VERSION_TAG_25" || -n "$MANUAL_VERSION_RELEASE_24" || -n "$MANUAL_VERSION_RELEASE_25" ]]; then
    echo "${YELLOW}Manual latest-version override active.${RESET}"
  fi

  if [[ "$DEBUG" -eq 1 ]]; then
    echo "${DIM}Debug: enabled | connect-timeout=${CONNECT_TIMEOUT}s | get-timeout=${GET_MAX_TIME}s | post-timeout=${POST_MAX_TIME}s${RESET}"
  fi

  echo
  echo "Latest 2.4.x: ${BOLD}${VERSION_TAG_24}${RESET}   Release: ${VERSION_RELEASE_24:-n/a}"
  echo "Latest 2.5.x: ${BOLD}${VERSION_TAG_25}${RESET}    Release: ${VERSION_RELEASE_25:-n/a}"
  echo
}

function print_table_header {
  printf "%-35s  %-12s  %-12s  %-20s\n" "Host" "Installed" "Latest" "Status"
  hr
}

function print_row {
  local host="$1"
  local installed="$2"
  local latest="$3"
  local status="$4"

  printf "%-35s  %-12s  %-12s  %b\n" "$host" "$installed" "$latest" "$status"
}

function print_checking {
  local host="$1"
  printf "%-35s  %-12s  %-12s  %b\r" "$host" "..." "..." "${DIM}checking...${RESET}"
}

function clear_line {
  printf "\r%*s\r" 120 ""
}

function api_post {
  local host="$1"
  local key="$2"
  local path="$3"
  local url="https://${host}${path}"

  local tmp_body
  local tmp_err
  tmp_body=$(mktemp)
  tmp_err=$(mktemp)

  local http_code
  http_code=$(curl -sS \
    --connect-timeout "$CONNECT_TIMEOUT" \
    --max-time "$POST_MAX_TIME" \
    -o "$tmp_body" \
    -w "%{http_code}" \
    -d '[]' \
    -H "Authorization: $key" \
    -H "Accept: application/json" \
    -H "Content-type: application/json" \
    -X POST \
    "$url" \
    2>"$tmp_err")

  local curl_rc=$?
  local body
  local curl_err
  body=$(cat "$tmp_body")
  curl_err=$(cat "$tmp_err")
  rm -f "$tmp_body" "$tmp_err"

  if [[ $curl_rc -ne 0 ]]; then
    printf '000\ncurl failed with exit code %s\n%s\nURL: %s\nconnect-timeout: %ss\nmax-time: %ss\n' \
      "$curl_rc" "$curl_err" "$url" "$CONNECT_TIMEOUT" "$POST_MAX_TIME"
  else
    printf '%s\n%s\n' "$http_code" "$body"
  fi
}

function api_get {
  local host="$1"
  local key="$2"
  local path="$3"
  local url="https://${host}${path}"

  local tmp_body
  local tmp_err
  tmp_body=$(mktemp)
  tmp_err=$(mktemp)

  local http_code
  http_code=$(curl -sS \
    --connect-timeout "$CONNECT_TIMEOUT" \
    --max-time "$GET_MAX_TIME" \
    -o "$tmp_body" \
    -w "%{http_code}" \
    -H "Authorization: $key" \
    -H "Accept: application/json" \
    -H "Content-type: application/json" \
    "$url" \
    2>"$tmp_err")

  local curl_rc=$?
  local body
  local curl_err
  body=$(cat "$tmp_body")
  curl_err=$(cat "$tmp_err")
  rm -f "$tmp_body" "$tmp_err"

  if [[ $curl_rc -ne 0 ]]; then
    printf '000\ncurl failed with exit code %s\n%s\nURL: %s\nconnect-timeout: %ss\nmax-time: %ss\n' \
      "$curl_rc" "$curl_err" "$url" "$CONNECT_TIMEOUT" "$GET_MAX_TIME"
  else
    printf '%s\n%s\n' "$http_code" "$body"
  fi
}

function misp_response_failed {
  local http_code="$1"
  local body="$2"

  if [[ ! "$http_code" =~ ^2 ]]; then
    return 0
  fi

  if ! is_json "$body"; then
    return 0
  fi

  echo "$body" | jq -e '
      (.name? // "" | test("permission|error|failed|denied|forbidden|unauthori"; "i"))
   or (.message? // "" | test("permission|error|failed|denied|forbidden|unauthori"; "i"))
   or (.errors? != null)
   or (.url? != null and (.name? != null or .message? != null))
   or (.status? != null and (.status|tostring) != "0" and (.status|tostring) != "success")
  ' >/dev/null 2>&1
}

function update_progress_blocked {
  local body="$1"

  echo "$body" | jq -e '
    (.update_locked == true)
    or (.update_fail_number_reached == true)
    or ((.complete_update_remaining // "0" | tostring) != "0")
  ' >/dev/null 2>&1
}

function update_progress_reason {
  local body="$1"
  local reasons=()

  if echo "$body" | jq -e '.update_locked == true' >/dev/null 2>&1; then
    reasons+=("locked")
  fi

  if echo "$body" | jq -e '.update_fail_number_reached == true' >/dev/null 2>&1; then
    reasons+=("fail-limit")
  fi

  if echo "$body" | jq -e '((.complete_update_remaining // "0" | tostring) != "0")' >/dev/null 2>&1; then
    reasons+=("db-update-remaining")
  fi

  local IFS=", "
  echo "${reasons[*]}"
}

function extract_error_message {
  local body="$1"

  if is_json "$body"; then
    echo "$body" | jq -r '.message // .name // .errors // empty' 2>/dev/null
  else
    echo "$body"
  fi
}

function print_debug_response {
  local body="$1"

  if [[ "$DEBUG" -eq 1 ]]; then
    echo
    echo "${DIM}Debug response:${RESET}"
    if is_json "$body"; then
      echo "$body" | jq
    else
      echo "$body"
    fi
  fi
}

function update_server {
  local HOST="$1"
  local KEY="$2"

  ../matrix.sh/matrix.sh "Currently updating MISP server $HOST. Cross your fingers!" 2>/dev/null || true

  echo
  echo "${BOLD}${BLUE}▶ Updating ${HOST}${RESET}"
  echo

  local RESPONSE
  local HTTP_CODE
  local BODY
  local MSG

  RESPONSE=$(api_post "$HOST" "$KEY" "/servers/update")
  HTTP_CODE=$(echo "$RESPONSE" | head -n 1)
  BODY=$(echo "$RESPONSE" | tail -n +2)

  if misp_response_failed "$HTTP_CODE" "$BODY"; then
    MSG=$(extract_error_message "$BODY")
    echo "  ${RED}✗ MISP core update failed${RESET}"
    echo "    HTTP ${HTTP_CODE}"
    [[ -n "$MSG" ]] && echo "    $MSG"
    print_debug_response "$BODY"
    return 1
  else
    echo "  ${GREEN}✓ MISP core updated or already current${RESET}"
  fi

  RESPONSE=$(api_post "$HOST" "$KEY" "/servers/updateJSON/async:1")
  HTTP_CODE=$(echo "$RESPONSE" | head -n 1)
  BODY=$(echo "$RESPONSE" | tail -n +2)

  if misp_response_failed "$HTTP_CODE" "$BODY"; then
    MSG=$(extract_error_message "$BODY")
    echo "  ${RED}✗ JSON update failed${RESET}"
    echo "    HTTP ${HTTP_CODE}"
    [[ -n "$MSG" ]] && echo "    $MSG"
    print_debug_response "$BODY"
    return 1
  else
    echo "  ${GREEN}✓ JSON cache update triggered or already current${RESET}"
  fi

  return 0
}

function ask_update {
  local host="$1"
  local installed="$2"
  local latest="$3"

  echo
  hr
  echo "${BOLD}Host:${RESET}      $host"
  echo "${BOLD}Installed:${RESET} $installed"
  echo "${BOLD}Latest:${RESET}    $latest"
  echo
  echo -en "Update this server? ${BOLD}[y]es/[n]o/[c]ancel:${RESET} "
  read -r input
  input="${input:0:1}"
}

function print_summary {
  echo
  big_hr
  echo
  echo "${BOLD}Summary${RESET}"
  echo

  printf "  ${GREEN}%-22s${RESET}: %s\n" "✓ Updated" "$UPDATED"
  printf "  ${GREEN}%-22s${RESET}: %s\n" "✓ Up-to-date" "$SKIPPED"
  printf "  ${RED}%-22s${RESET}: %s\n" "✗ Failed" "$FAILED"
  printf "  ${RED}%-22s${RESET}: %s\n" "🔒 Auth failed" "$AUTH_FAILED"
  printf "  ${YELLOW}%-22s${RESET}: %s\n" "⚠ Unreachable" "$UNREACHABLE"
  printf "  ${YELLOW}%-22s${RESET}: %s\n" "🔒 DB locked" "$DB_LOCKED"
  printf "  ${RED}%-22s${RESET}: %s\n" "✗ Latest unknown" "$LATEST_UNKNOWN"

  echo
  big_hr
}

while IFS=, read -r HOST KEY REST; do
  HOST=$(echo "$HOST" | tr -d '\r' | xargs)
  KEY=$(echo "$KEY" | tr -d '\r' | xargs)

  [[ -z "$HOST" ]] && continue
  [[ "$HOST" =~ ^# ]] && continue

  HOSTS+=("$HOST")
  KEYS+=("$KEY")
done < "$CONFIG"

if [[ ${#HOSTS[@]} -eq 0 ]]; then
  echo "No hosts found in $CONFIG. Aborting."
  exit 1
fi

print_title
print_table_header

for ((i=0; i<${#HOSTS[@]}; i++)); do
  HOST="${HOSTS[$i]}"
  KEY="${KEYS[$i]}"

  print_checking "$HOST"

  if [[ -z "$KEY" ]]; then
    clear_line
    print_row "$HOST" "n/a" "n/a" "${FAILED_TXT} missing API key"
    FAILED=$((FAILED + 1))
    continue
  fi

  RESPONSE=$(api_get "$HOST" "$KEY" "/servers/getVersion")
  HTTP_CODE=$(echo "$RESPONSE" | head -n 1)
  RESP=$(echo "$RESPONSE" | tail -n +2)

  if [[ "$HTTP_CODE" == "000" ]]; then
    clear_line
    print_row "$HOST" "n/a" "n/a" "$UNREACHABLE_TXT"
    [[ "$DEBUG" -eq 1 ]] && echo "$RESP"
    UNREACHABLE=$((UNREACHABLE + 1))
    continue
  fi

  if [[ ! "$HTTP_CODE" =~ ^2 ]]; then
    clear_line
    print_row "$HOST" "n/a" "n/a" "${FAILED_TXT} HTTP $HTTP_CODE"
    print_debug_response "$RESP"
    FAILED=$((FAILED + 1))
    continue
  fi

  if echo "$RESP" | grep -qi "Authentication failed"; then
    clear_line
    print_row "$HOST" "n/a" "n/a" "$AUTH_TXT"
    AUTH_FAILED=$((AUTH_FAILED + 1))
    continue
  fi

  if ! is_json "$RESP"; then
    clear_line
    print_row "$HOST" "n/a" "n/a" "${FAILED_TXT} invalid JSON"
    print_debug_response "$RESP"
    FAILED=$((FAILED + 1))
    continue
  fi

  VERSION_RUNNING=$(echo "$RESP" | jq -r ".[]" | head -n 1 | tr -d '\r\n')

  if [[ -z "$VERSION_RUNNING" || "$VERSION_RUNNING" == "null" ]]; then
    VERSION_RUNNING="n/a"
  fi

  if [[ "$VERSION_RUNNING" =~ ^2\.4\. ]]; then
    VERSION_TAG="$VERSION_TAG_24"
  else
    VERSION_TAG="$VERSION_TAG_25"
  fi

  if [[ -z "$VERSION_TAG" || "$VERSION_TAG" == "n/a" ]]; then
    clear_line
    print_row "$HOST" "$VERSION_RUNNING" "n/a" "$LATEST_UNKNOWN_TXT"
    LATEST_UNKNOWN=$((LATEST_UNKNOWN + 1))
    continue
  fi

  if [[ "$VERSION_RUNNING" == "$VERSION_TAG" ]]; then
    clear_line
    print_row "$HOST" "$VERSION_RUNNING" "$VERSION_TAG" "$OK"
    SKIPPED=$((SKIPPED + 1))
  else
    PROGRESS_RESPONSE=$(api_get "$HOST" "$KEY" "/servers/updateProgress.json")
    PROGRESS_HTTP_CODE=$(echo "$PROGRESS_RESPONSE" | head -n 1)
    PROGRESS_BODY=$(echo "$PROGRESS_RESPONSE" | tail -n +2)

    if [[ "$PROGRESS_HTTP_CODE" =~ ^2 ]] && is_json "$PROGRESS_BODY"; then
      if update_progress_blocked "$PROGRESS_BODY"; then
        REASON=$(update_progress_reason "$PROGRESS_BODY")
        clear_line
        print_row "$HOST" "$VERSION_RUNNING" "$VERSION_TAG" "${DB_LOCKED_TXT} ${REASON}"
        [[ "$DEBUG" -eq 1 ]] && print_debug_response "$PROGRESS_BODY"
        DB_LOCKED=$((DB_LOCKED + 1))
        continue
      fi
    elif [[ "$DEBUG" -eq 1 ]]; then
      clear_line
      print_row "$HOST" "$VERSION_RUNNING" "$VERSION_TAG" "${OUTDATED} progress-check-failed"
      print_debug_response "$PROGRESS_BODY"
    fi

    clear_line
    print_row "$HOST" "$VERSION_RUNNING" "$VERSION_TAG" "$OUTDATED"

    if [[ "$AUTO_MODE" -eq 1 ]]; then
      echo
      echo "${DIM}Auto mode enabled - updating ${HOST}.${RESET}"
      input="y"
    else
      ask_update "$HOST" "$VERSION_RUNNING" "$VERSION_TAG"
    fi

    case "$input" in
      "y"|"Y")
        if update_server "$HOST" "$KEY"; then
          UPDATED=$((UPDATED + 1))
        else
          FAILED=$((FAILED + 1))
        fi

        if (( i < ${#HOSTS[@]} - 1 )); then
          echo
          print_table_header
        fi
        ;;
      "n"|"N")
        echo "${DIM}Skipping ${HOST}.${RESET}"
        SKIPPED=$((SKIPPED + 1))
        ;;
      "c"|"C")
        echo
        echo "${YELLOW}Cancelling the process.${RESET}"
        print_summary
        exit 1
        ;;
      *)
        echo "${DIM}Invalid input, not updating ${HOST}.${RESET}"
        SKIPPED=$((SKIPPED + 1))
        ;;
    esac
  fi
done

print_summary
