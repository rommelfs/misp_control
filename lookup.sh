#!/bin/bash
# lookup users
# config file needed (config.csv)
# fields:
# server_name,API_key
# 2021-06 Sascha Rommelfangen, CIRCL, SMILE


command="$1"
on_server="$2"
search="$3"

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

function search_id (){
  for line in `cat config.csv | grep -v '^#' |grep $on_server`
  do 
    server=$(echo $line | cut -d "," -f 1)
    echo -n "Working on server $server... "
    apikey=$(echo $line | cut -d "," -f 2)
    result=$(curl -s -H "Authorization: ${apikey}" -H "Accept: application/json" -H "Content-Type: application/json" -X GET https://${server}/users/view/{$search}.json)
    if [[ "$result" != '[]' ]]
    then
      echo "found $search"
      echo $result |jq -r ".User.email"
      #parse true "$result"
    else echo "$search not found"
    fi
  done
}

function search_ip (){
  for line in `cat config.csv | grep -v '^#' |grep $on_server`
  do 
    server=$(echo $line | cut -d "," -f 1)
    echo -n "Working on server $server... "
    apikey=$(echo $line | cut -d "," -f 2)
    result=$(curl -s -H "Authorization: ${apikey}" -H "Accept: application/json" -H "Content-Type: application/json" -X POST https://${server}/servers/ipUser -d "{\"ip\":\"$search\"}")
    if [[ "$result" != '[]' ]]
    then
      echo "found $search"
      email=`echo $result | jq -r '.[].email'`
      echo "$search: $email"
      #parse true "$result"
    else echo "$search not found"
    fi
  done
}



function show_help {
  echo -e "Usage:\t$0 [-s|-d|-x] ID"
#  echo -e "\t$0 -s email_address (search user by email address)"
#  echo -e "\t$0 -d email_address (disable email auto alerts)"
#  echo -e "\t$0 -e email_address (enable email auto alerts)"
#  echo -e "\t$0 -x email_address (disable user)"
#  echo -e "\t$0 -y email_address (enable user)"
  echo -e "\t$0 -i userid)"
}

case "$command" in
  -uid) 
      search_id $user $on_server
      exit 0
  ;;
  -ip) 
      search_ip $user $on_server
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
