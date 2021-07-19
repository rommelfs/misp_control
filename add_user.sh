#!/usr/local/bin/bash 
# add user script
# config file needed (config.csv)
# fields:
# server_name,API_key
# 2021-06 Sascha Rommelfangen, CIRCL, SMILE


command="$1"
user="$2"
declare -A config
declare selected_server
declare org_id
declare server
declare apikey
declare id

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
  echo -e " Last Login:\t$(date -r ${current})"
  echo -e " Autoalert:\t${alert}"
  echo -e " Disabled:\t${disabled}"
}

function select_org (){
#  IFS=$' '
#  echo $@
  n=0
  declare -A orgs
  for field in `echo $@ | jq -r ".[].Organisation.id"`
  do
    export FIELD=$field
    orgs[$n,0]=$field
    orgs[$n,1]=`echo $@ | jq -r ".[] | select(.Organisation.id == env.FIELD) | .Organisation.name"`
    n=$((n+1))
  done
  total=${#orgs[*]}
  total=$((total/2)) # due to multidimensional array, size is 0.5
  for (( i=0; i<=$(( $total -1 )); i++ ))
  do 
    echo -e "\t($i): ID: ${orgs[$i,0]}\tName: ${orgs[$i,1]}"
  done
  if [[ "$total" -gt 1 ]]
  then
    read -rp "Search resulted several matches. Please select the correct Organisation: " num_org
    org_id=${orgs[$num_org,0]}
    org_name=${orgs[$num_org,1]}
    if [[ -z $org_id || -z $org_name ]]
    then
        echo "Something went wrong. Exiting"
        exit 1
    fi
    echo "You selected $org_name ($org_id)"
  else
      org_id=${orgs[0,0]}
  fi
}



function find_user (){
  user="$1"
  server=${config[$selected_server,0]}
  apikey=${config[$selected_server,1]}
  echo -n "Working on server $server... "
  result=$(curl -s -H "Authorization: ${apikey}" -H "Accept: application/json" -H "Content-Type: application/json" -X GET https://${server}/users/admin_index/value:${user}.json)
  if [[ "$result" != '[]' ]]
  then
    #echo "found $user"
    parse true "$result"
    return 0
  else 
    #echo "$user not found"
    return 1
  fi
}

function find_org(){
  org="$1"
  if [[ $org == "INVALID" ]]
  then
      exit 1
  fi
  server=${config[$selected_server,0]}
  apikey=${config[$selected_server,1]}
  echo -n "Working on server $server... "
  result=$(curl -s -H "Authorization: ${apikey}" -H "Accept: application/json" -H "Content-Type: application/json" -X GET https://${server}/organisations/index/searchall:${org}.json)
  if [[ "$result" != '[]' ]]
  then
    echo -e "\nOrganisation $org found"
    select_org $result
  else 
    echo -e "\nOrganisation $org not found"
    return 0
  fi
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

function select_server (){
  n=0
  echo "Select server:"
  for line in `cat config.csv |grep -v '^#'`
  do
      server=$(echo $line| cut -d "," -f 1)
      apikey=$(echo $line | cut -d "," -f 2)
      config[$n,0]=$server
      config[$n,1]=$apikey
      echo -e "\t($n)\t$server"
      n=$((n+1))
  done
  printf '%s ' 'Which server would you like to work on: ' 
  read selected_server
  echo "You selected: ${config[$selected_server,0]}"
}


function create_user (){
  user="$1"
  select_server
  if find_user $user
  then
      echo "User already exists. Exiting."
      exit 0
  else
      echo -e "\nUser ${user} doesn't exist on ${config[$selected_server,0]}"
      org=$(propose_org $user)
      echo
      find_org "$org"
      #$org_id=$?
      if [[ "$org_id" -ne 0 ]]
      then
          echo "Preparing to create new user ${user} on organisation ${org} (${org_id})"
          add_user ${user} ${org_id} 3
      else
          echo "Preparing to create new organisation ${org}"
          org_id=$(add_org ${org} ${user})
          if [ "$org_id" -eq "$org_id" ]
          then
            echo "Successfully create organisation ${org} (${org_id})"
            add_user ${user} ${org_id} 2
          else
            echo "Something went wrong while creating organisation ${org}. Exiting."
            exit 1
          fi
      fi
  fi
}

function add_user (){
    user="$1"
    org_id="$2"
    role_id="$3"
    gpgkey=""
    certif_public=""
    echo -e "\t(1)   PGP Public Key"
    echo -e "\t(2)   S/MIME certificate"
    read -rp "Select type of key/certificate: " -n1 enc_type
    echo
    echo "Paste the key/certificate here (Send with Ctrl-D, cancel with Ctrl-C):"
    key=$(cat)
    key=$(echo "$key"|gsed -z -e 's/\n/\\n/g')
    if [ $enc_type -eq "1" ] 
    then 
      gpgkey="${key}"
    elif [ $enc_type -eq "2" ] 
    then 
      certif_public="${key}"
    fi
    printf -v server_action '{ "email": "%s", "org_id": "%s", "role_id": "%s", "gpgkey": "%s", "certif_public": "%s", "notify": 1 }' "${user}" "${org_id}" "${role_id}" "${gpgkey}" "${certif_public}"
    result=$(curl -s -H "Authorization: ${apikey}" -H "Accept: application/json" -H "Content-Type: application/json" -d "${server_action}" -X POST https://${server}/admin/users/add)
    user_id=$(echo $result|jq -r ".[].id")
    if [ "$user_id" -eq "$user_id" ]
    then
        echo "Successfully created user ${user} (${user_id}) with role ${role_id} on organisation ${org_id}"
    else
        echo "Something went wrong during user creation process. Exiting after dumping:"
        echo -e "Request:\n${server_action}"
        echo -e "Reply:\n${result}"
        exit 1
    fi
}


function add_org (){
    org="$1"
    email="$2"
    domain_restriction=$(echo $user | cut -d "@" -f 2)
    printf -v server_action '{ "name": "%s", "contacts": "%s", "restricted_to_domain": [ "%s" ] }' "${org}" "${email}" "${domain_restriction}"
    result=$(curl -s -H "Authorization: ${apikey}" -H "Accept: application/json" -H "Content-Type: application/json" -d "${server_action}" -X POST https://${server}/admin/organisations/add)
    org_id=$(echo $result|jq -r ".[].id")
    echo $org_id
}

function propose_org (){
    user="$1"
    proposed_org=$(echo $user | cut -d "@" -f 2)
    read  -rsp "Is ${proposed_org} the expected organisation name (Y/n/e): " -i "y" -n1 ret
    if [[ $ret == "n" ]] 
    then 
      proposed_org="INVALID"
    elif [[ $ret == "e" ]]
    then
        read -p "Enter new org name: " proposed_org
    fi
    echo $proposed_org
}

function reset_password (){
  user="$1"
  select_server
  if find_user $user
  then
    if [ "$id" -eq "$id" ]
    then
      result=$(curl -s -H "Authorization: ${apikey}" -H "Accept: application/json" -H "Content-Type: application/json" -X POST https://${server}/users/initiatePasswordReset/{$id})
      echo $result
    fi
  fi
}

function show_help {
  echo -e "Usage:\t$0 [-s|-d|-e|-x|-y|-r] email_address"
  echo -e "\t$0 -s email_address (search user by email address)"
  echo -e "\t$0 -c email_address (create user)"
  echo -e "\t$0 -r email_address (reset password)"
}

case "$command" in
  -s) 
      search $user
      exit 0
  ;;
  -c) 
      create_user $user
      exit 0
  ;;
  -r)
      reset_password $user
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
