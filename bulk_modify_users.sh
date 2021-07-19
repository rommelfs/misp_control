#!/bin/bash 
# bulk modify users, even on several servers.
# config file needed (config.csv)
# fields:
# server_name,API_key
# 2021-06 Sascha Rommelfangen, CIRCL, SMILE


command="$1"
user="$2"

function parse (){
  encapsulated="$1"
  shift
  IFS=$' '
  if [[ "$encapsulated" == "true" ]]
  then
    { read id; read email; read last; read current; read alert; read disabled; } <<< `echo $@ | jq -r ".[].User.id, .[].User.email, .[].User.last_login, .[].User.current_login, .[].User.autoalert, .[].User.disabled"`
  else
    { read id; read email; read last; read current; read alert; read disabled; } <<< `echo $@ | jq -r ".User.id, .User.email, .User.last_login, .User.current_login, .User.autoalert, .User.disabled"`
  fi
  echo -e " User ID:\t${id}"
  echo -e " Email:\t\t${email}"
  echo -e " Prev. Login:\t$(date -r ${last})"
  echo -e " Current Login:\t$(date -r ${current})"
  echo -e " Autoalert:\t${alert}"
  echo -e " Disabled:\t${disabled}"
}

function search (){
  for line in `cat config.csv | grep -v '^#'`
  do 
    server=$(echo $line | cut -d "," -f 1)
    echo -n "Working on server $server... "
    apikey=$(echo $line | cut -d "," -f 2)
    result=$(curl -s -H "Authorization: ${apikey}" -H "Accept: application/json" -H "Content-Type: application/json" -X GET https://${server}/users/admin_index/value:${user}.json)
    if [[ "$result" != '[]' ]]
    then
      echo "found $user"
      parse true "$result"
    else echo "$user not found"
    fi
  done
}

function modify_user (){
  action="$1"
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
  esac
    
  for line in `cat config.csv | grep -v '^#'`
  do 
    server=$(echo $line | cut -d "," -f 1)
    echo -n "Working on server $server... "
    apikey=$(echo $line | cut -d "," -f 2)
    result=$(curl -s -H "Authorization: ${apikey}" -H "Accept: application/json" -H "Content-Type: application/json" -X GET https://${server}/users/admin_index/value:${user}.json)
    user_id=$(echo $result | jq -r ".[].User.id")
    if [[ ! "$user_id" ]] 
    then 
      echo "$user not found"
    else
      echo "Modifying user $user ($user_id): $server_action"
      result=$(curl -s -H "Authorization: ${apikey}" -H "Accept: application/json" -H "Content-Type: application/json" -d "$server_action" -X POST https://${server}/admin/users/edit/${user_id})
      if [[ "$result" != '[]' ]]
      then
        parse false "$result"
      else echo "not found"
      fi
    fi
  done
}

function show_help {
  echo -e "Usage:\t$0 [-s|-d|-x] email_address"
  echo -e "\t$0 -s email_address (search user by email address)"
  echo -e "\t$0 -d email_address (disable email auto alerts)"
  echo -e "\t$0 -e email_address (enable email auto alerts)"
  echo -e "\t$0 -x email_address (disable user)"
  echo -e "\t$0 -y email_address (enable user)"
}

case "$command" in
  -s) 
      search $user
      exit 0
  ;;
  -e) 
      modify_user enable_autoalert $user
      exit 0
  ;;
  -d) 
      modify_user disable_autoalert $user
      exit 0
  ;;
  -x) 
      modify_user disable_user $user
      exit 0
  ;;
  -y) 
      modify_user enable_user $user
      exit 0
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
