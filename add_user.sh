#!/opt/homebrew/bin/bash
# add user script
# config file needed (config.csv)
# fields:
# server_name,API_key
# 2021-06 - 2026 Sascha Rommelfangen, CIRCL, LHC

set -o pipefail

CONFIG="config.csv"
DEBUG=0
USE_COLOR=1
CONNECT_TIMEOUT=10
GET_MAX_TIME=120
POST_MAX_TIME=300

command=""
user=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --debug) DEBUG=1; shift ;;
    --no-color) USE_COLOR=0; shift ;;
    --help|-h) command="-h"; shift ;;
    -s|-c|-r) command="$1"; user="$2"; shift 2 ;;
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

FOUND_TXT="${GREEN}✓ FOUND${RESET}"
MISS_TXT="${DIM}MISS${RESET}"
FAILED_TXT="${RED}✗ FAILED${RESET}"
AUTH_TXT="${RED}🔒 AUTH FAILED${RESET}"
UNREACHABLE_TXT="${YELLOW}⚠ UNREACHABLE${RESET}"
OK_TXT="${GREEN}✓ OK${RESET}"
WARN_TXT="${YELLOW}⚠ WARN${RESET}"

SEARCH_FOUND=0
SEARCH_MISSED=0
SEARCH_FAILED=0
SEARCH_AUTH_FAILED=0
SEARCH_UNREACHABLE=0

HOSTS=()
KEYS=()

declare -A config
declare selected_server
declare org_id
declare server
declare apikey
declare id

REQUIRED_CMDS=("curl" "jq" "tr" "xargs" "mktemp")

function validate_environment (){
  for cmd in "${REQUIRED_CMDS[@]}"; do
    command -v "$cmd" >/dev/null 2>&1 || {
      echo "${RED}[!] Required command missing: $cmd${RESET}"
      exit 1
    }
  done

  if [[ ! -f "$CONFIG" ]]; then
    echo "${RED}[!] Config file $CONFIG missing. Aborting.${RESET}"
    exit 1
  fi
}

function load_config (){
  local host
  local key
  local rest

  while IFS=, read -r host key rest; do
    host=$(echo "$host" | tr -d '\r' | xargs)
    key=$(echo "$key" | tr -d '\r' | xargs)

    [[ -z "$host" ]] && continue
    [[ "$host" =~ ^# ]] && continue

    HOSTS+=("$host")
    KEYS+=("$key")
  done < "$CONFIG"

  if [[ ${#HOSTS[@]} -eq 0 ]]; then
    echo "${RED}[!] No hosts found in $CONFIG. Aborting.${RESET}"
    exit 1
  fi
}

function hr {
  printf "%s\n" "${DIM}--------------------------------------------------------------------------------${RESET}"
}

function big_hr {
  printf "%s\n" "${DIM}================================================================================${RESET}"
}

function is_json {
  echo "$1" | jq empty >/dev/null 2>&1
}

function print_title {
  echo
  echo "${BOLD}${CYAN}MISP User Admin Helper${RESET}"
  echo "${DIM}Config: $CONFIG${RESET}"

  if [[ "$DEBUG" -eq 1 ]]; then
    echo "${DIM}Debug: enabled | connect-timeout=${CONNECT_TIMEOUT}s | get-timeout=${GET_MAX_TIME}s | post-timeout=${POST_MAX_TIME}s${RESET}"
  fi

  echo
}

function print_table_header {
  printf "%-35s  %-18s  %-s\n" "Host" "Status" "Message"
  hr
}

function print_row {
  local host="$1"
  local status="$2"
  local message="$3"

  printf "%-35s  %-18b  %s\n" "$host" "$status" "$message"
}

function print_checking {
  local host="$1"
  printf "%-35s  %-18s  %b\r" "$host" "..." "${DIM}checking...${RESET}"
}

function clear_line {
  printf "\r%*s\r" 120 ""
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

function print_search_summary {
  echo
  big_hr
  echo
  echo "${BOLD}Summary${RESET}"
  echo

  printf "  ${GREEN}%-22s${RESET}: %s\n" "✓ Found" "$SEARCH_FOUND"
  printf "  ${DIM}%-22s${RESET}: %s\n" "Miss" "$SEARCH_MISSED"
  printf "  ${RED}%-22s${RESET}: %s\n" "✗ Failed" "$SEARCH_FAILED"
  printf "  ${RED}%-22s${RESET}: %s\n" "🔒 Auth failed" "$SEARCH_AUTH_FAILED"
  printf "  ${YELLOW}%-22s${RESET}: %s\n" "⚠ Unreachable" "$SEARCH_UNREACHABLE"

  echo
  big_hr
}

function print_info (){
  echo "    $*"
}

function print_ok (){
  echo "${GREEN}✓ $*${RESET}"
}

function print_warn (){
  echo "${YELLOW}⚠ $*${RESET}" >&2
}

function print_error (){
  echo "${RED}[!] $*${RESET}" >&2
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

function api_post {
  local host="$1"
  local key="$2"
  local path="$3"
  local data="${4:-[]}"
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
    -d "$data" \
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

function extract_error_message {
  local body="$1"

  if is_json "$body"; then
    echo "$body" | jq -r '.message // .name // .errors // empty' 2>/dev/null
  else
    echo "$body"
  fi
}

function find_user (){
  local search_user="$1"
  local result
  local http_code
  local body

  server=${config[$selected_server,0]}
  apikey=${config[$selected_server,1]}

  print_info "Checking server: $server"
  result=$(api_get "$server" "$apikey" "/users/admin_index/value:${search_user}.json")
  http_code=$(echo "$result" | head -n 1)
  body=$(echo "$result" | tail -n +2)

  if [[ "$http_code" == "000" ]]; then
    print_warn "Unreachable: $server"
    [[ "$DEBUG" -eq 1 ]] && echo "$body"
    return 1
  fi

  if [[ ! "$http_code" =~ ^2 ]]; then
    print_warn "HTTP $http_code on $server"
    print_debug_response "$body"
    return 1
  fi

  if echo "$body" | grep -qi "Authentication failed"; then
    print_warn "Authentication failed on $server"
    return 1
  fi

  if ! is_json "$body"; then
    print_warn "Invalid JSON from $server"
    print_debug_response "$body"
    return 1
  fi

  if [[ "$body" != '[]' ]]
  then
    parse true "$body"
    return 0
  fi

  return 1
}

function find_org(){
  local org="$1"
  local result

  if [[ "$org" == "INVALID" ]]
  then
    exit 1
  fi

  server=${config[$selected_server,0]}
  apikey=${config[$selected_server,1]}

  echo -n "Working on server $server... "
  result=$(api_get "$server" "$apikey" "/organisations/index/searchall:${org}.json")
  result=$(echo "$result" | tail -n +2)

  if [[ "$result" != '[]' ]]
  then
    echo -e "\nOrganisation $org found"
    select_org "$result"
  else
    echo -e "\nOrganisation $org not found"
    org_id=0
    return 1
  fi
}

function modify_user (){
  local action="$1"
  local server_action
  local result
  local user_id

  case "$action" in
    disable_autoalert)
      server_action='{ "autoalert": false }'
    ;;
    enable_autoalert)
      server_action='{ "autoalert": true }'
    ;;
    disable_user)
      server_action='{ "disabled": true }'
    ;;
    enable_user)
      server_action='{ "disabled": false }'
    ;;
    *)
      echo "Unknown modify action: $action" >&2
      return 1
    ;;
  esac

  while IFS=, read -r server apikey
  do
    [[ -z "$server" || "$server" =~ ^# ]] && continue
    server=${server//$'\r'/}
    apikey=${apikey//$'\r'/}

    echo -n "Working on server $server... "
    result=$(api_get "$server" "$apikey" "/users/admin_index/value:${user}.json")
    result=$(echo "$result" | tail -n +2)
    user_id=$(printf '%s' "$result" | jq -r ".[].User.id")

    if [[ -z "$user_id" ]]
    then
      print_row "$server" "$MISS_TXT" "$user not found"
    else
      print_row "$server" "$OK_TXT" "Modifying user $user ($user_id): $server_action"
      result=$(api_post "$server" "$apikey" "/admin/users/edit/${user_id}" "$server_action")
      result=$(echo "$result" | tail -n +2)
      if [[ "$result" != '[]' ]]
      then
        parse false "$result"
      else
        print_row "$server" "$MISS_TXT" "not found"
      fi
    fi
  done < config.csv
}

function select_server (){
  local n=0

  echo "Select server:"
  while IFS=, read -r server apikey
  do
    [[ -z "$server" || "$server" =~ ^# ]] && continue
    server=${server//$'\r'/}
    apikey=${apikey//$'\r'/}
    config[$n,0]="$server"
    config[$n,1]="$apikey"
    echo -e "\t($n)\t$server"
    n=$((n+1))
  done < config.csv

  if [[ "$n" -eq 0 ]]
  then
    echo "No usable servers found in config.csv" >&2
    exit 1
  fi

  printf '%s ' 'Which server would you like to work on: '
  read -r selected_server

  if [[ -z "${config[$selected_server,0]}" || -z "${config[$selected_server,1]}" ]]
  then
    echo "Invalid server selection: ${selected_server}" >&2
    exit 1
  fi

  echo "You selected: ${config[$selected_server,0]}"
}

function create_user (){
  local create_user_email="$1"
  local org

  select_server
  if find_user "$create_user_email"
  then
    echo "User already exists. Exiting."
    exit 0
  fi

  echo -e "\nUser ${create_user_email} doesn't exist on ${config[$selected_server,0]}"
  org=$(propose_org "$create_user_email")
  echo

  if find_org "$org"
  then
    echo "Preparing to create new user ${create_user_email} on organisation ${org} (${org_id})"
    add_user "$create_user_email" "$org_id" 3
  else
    echo "Preparing to create new organisation ${org}"
    org_id=$(add_org "$org" "$create_user_email")
    if is_number "$org_id"
    then
      echo "Successfully created organisation ${org} (${org_id})"
      add_user "$create_user_email" "$org_id" 2
    else
      echo "Something went wrong while creating organisation ${org}. Exiting."
      exit 1
    fi
  fi
}

function add_user (){
  local add_user_email="$1"
  local add_user_org_id="$2"
  local role_id="$3"
  local gpgkey=""
  local certif_public=""
  local enc_type
  local key
  local server_action
  local result
  local user_id

  echo -e "\t(1)   PGP Public Key"
  echo -e "\t(2)   S/MIME certificate"
  read -r -p "Select type of key/certificate: " -n1 enc_type
  echo
  echo "Paste the key/certificate here (Send with Ctrl-D, cancel with Ctrl-C):"
  key=$(cat)
  key=$(printf '%s' "$key" | sed -z -e 's/\n/\\n/g')

  if [[ "$enc_type" == "1" ]]
  then
    gpgkey="$key"
  elif [[ "$enc_type" == "2" ]]
  then
    certif_public="$key"
  fi

  server_action=$(jq -n \
    --arg email "$add_user_email" \
    --arg org_id "$add_user_org_id" \
    --arg role_id "$role_id" \
    --arg gpgkey "$gpgkey" \
    --arg certif_public "$certif_public" \
    '{ email: $email, org_id: $org_id, role_id: $role_id, gpgkey: $gpgkey, certif_public: $certif_public, notify: 1 }')

  result=$(api_post "$server" "$apikey" "/admin/users/add" "$server_action")
  result=$(echo "$result" | tail -n +2)
  user_id=$(printf '%s' "$result" | jq -r ".[].id")

  if is_number "$user_id"
  then
    echo "Successfully created user ${add_user_email} (${user_id}) with role ${role_id} on organisation ${add_user_org_id}"
  else
    echo "Something went wrong during user creation process. Exiting after dumping:"
    echo -e "Request:\n${server_action}"
    echo -e "Reply:\n${result}"
    exit 1
  fi
}

function add_org (){
  local org="$1"
  local email="$2"
  local domain_restriction
  local server_action
  local result
  local new_org_id

  domain_restriction=$(printf '%s' "$email" | cut -d "@" -f 2)
  server_action=$(jq -n \
    --arg name "$org" \
    --arg contacts "$email" \
    --arg domain "$domain_restriction" \
    '{ name: $name, contacts: $contacts, restricted_to_domain: [ $domain ] }')

  result=$(api_post "$server" "$apikey" "/admin/organisations/add" "$server_action")
  result=$(echo "$result" | tail -n +2)
  new_org_id=$(printf '%s' "$result" | jq -r ".[].id")
  echo "$new_org_id"
}

function propose_org (){
  local proposed_user="$1"
  local proposed_org
  local ret

  proposed_org=$(printf '%s' "$proposed_user" | cut -d "@" -f 2)
  read -e -r -p "Is ${proposed_org} the expected organisation name (Y/n/e): " -i "y" -n1 ret
  echo

  if [[ "$ret" == "n" ]]
  then
    proposed_org="INVALID"
  elif [[ "$ret" == "e" ]]
  then
    read -r -p "Enter new org name: " proposed_org
  fi

  echo "$proposed_org"
}

function reset_password (){
  local reset_user="$1"
  local result

  if [[ -z "$reset_user" ]]
  then
    echo "Missing email address for password reset." >&2
    show_help
    return 1
  fi

  select_server
  if find_user "$reset_user"
  then
    if is_number "$id"
    then
      result=$(api_post "$server" "$apikey" "/users/initiatePasswordReset/${id}" "[]")
      result=$(echo "$result" | tail -n +2)
      echo "$result"
      return 0
    fi
  fi

  echo "$reset_user not found on ${config[$selected_server,0]}"
  return 1
}

function search (){
  local search_user="$1"
  local response
  local http_code
  local body
  local msg

  if [[ -z "$search_user" ]]
  then
    echo "${RED}[!] Missing email address for search.${RESET}"
    show_help
    return 1
  fi

  print_title
  echo "${BOLD}Search:${RESET} $search_user"
  echo
  print_table_header

  for ((i=0; i<${#HOSTS[@]}; i++)); do
    server="${HOSTS[$i]}"
    apikey="${KEYS[$i]}"

    print_checking "$server"

    if [[ -z "$apikey" ]]; then
      clear_line
      print_row "$server" "$FAILED_TXT" "missing API key"
      SEARCH_FAILED=$((SEARCH_FAILED + 1))
      continue
    fi

    response=$(api_get "$server" "$apikey" "/users/admin_index/value:${search_user}.json")
    http_code=$(echo "$response" | head -n 1)
    body=$(echo "$response" | tail -n +2)

    if [[ "$http_code" == "000" ]]; then
      clear_line
      print_row "$server" "$UNREACHABLE_TXT" ""
      [[ "$DEBUG" -eq 1 ]] && echo "$body"
      SEARCH_UNREACHABLE=$((SEARCH_UNREACHABLE + 1))
      continue
    fi

    if [[ ! "$http_code" =~ ^2 ]]; then
      clear_line
      print_row "$server" "$FAILED_TXT" "HTTP $http_code"
      print_debug_response "$body"
      SEARCH_FAILED=$((SEARCH_FAILED + 1))
      continue
    fi

    if echo "$body" | grep -qi "Authentication failed"; then
      clear_line
      print_row "$server" "$AUTH_TXT" ""
      SEARCH_AUTH_FAILED=$((SEARCH_AUTH_FAILED + 1))
      continue
    fi

    if ! is_json "$body"; then
      clear_line
      print_row "$server" "$FAILED_TXT" "invalid JSON"
      print_debug_response "$body"
      SEARCH_FAILED=$((SEARCH_FAILED + 1))
      continue
    fi

    if [[ "$body" != '[]' ]]; then
      msg=$(echo "$body" | jq -r '.[0].User.id as $id | .[0].User.email as $email | "id=" + ($id|tostring) + " " + $email' 2>/dev/null)
      clear_line
      print_row "$server" "$FOUND_TXT" "$msg"
      SEARCH_FOUND=$((SEARCH_FOUND + 1))
      if [[ "$DEBUG" -eq 1 ]]; then
        parse true "$body"
      fi
    else
      clear_line
      print_row "$server" "$MISS_TXT" "not found"
      SEARCH_MISSED=$((SEARCH_MISSED + 1))
    fi
  done

  print_search_summary

  if [[ "$SEARCH_FOUND" -gt 0 ]]; then
    return 0
  fi

  if [[ "$SEARCH_FAILED" -gt 0 || "$SEARCH_AUTH_FAILED" -gt 0 || "$SEARCH_UNREACHABLE" -gt 0 ]]; then
    return 2
  fi

  return 1
}

validate_environment
load_config

case "$command" in
  -s)
    search "$user"
    exit $?
  ;;
  -c)
    create_user "$user"
    exit $?
  ;;
  -r)
    reset_password "$user"
    exit $?
  ;;
  -h)
    show_help
    exit 0
  ;;
  *)
    show_help
    exit 0
  ;;
esac
