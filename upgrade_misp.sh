#!/bin/bash

# upgrade all MISP servers stored in config.csv
# config file needed (config.csv)
# fields:
# server_name,API_key
# 2024-03 Sascha Rommelfangen, CIRCL, LHC

function update_server { 
  HOST="$1"
  KEY="$2"
  RESULT=$(curl -s -d '[]' -H "Authorization: $KEY" -H "Accept: application/json" -H "Content-type: application/json" -X POST https://$HOST/servers/update )
  #echo "$RESULT"
  if [[ $(echo $RESULT|jq|egrep -e "status|Update failed"|grep -v 0) ]]
  then
      echo -en "  => Something went wrong. Do you want to see the output? (y/n): "
      read -r -s -n 1 input
      echo $input
      case "$input" in
		"y")
            echo ${RESULT} | jq
			;;
		"n")
			;;
	  esac
  else
      echo "  => Updated successfully or no update available"
  fi
}


# get release version
VERSION_RELEASE=$( curl -s -I https://github.com/MISP/MISP/releases/latest |grep location | rev | cut -d "/" -f 1|rev|cut -d "v" -f 2 )
VERSION_RELEASE="${VERSION_RELEASE%%[[:cntrl:]]}"

# get tag version
VERSION_TAG=$( curl -s https://github.com/MISP/MISP/tags|grep /MISP/MISP/releases/tag/|head -n 1|rev|cut -d "<" -f 3|cut -d ">" -f 1|rev|cut -d "v" -f 2 )
VERSION_TAG="${VERSION_TAG%%[[:cntrl:]]}"

CONFIG="config.csv"

if [ ! -f $CONFIG ]
then
  echo "Config file $CONFIG missing. Aborting."
  exit 1
fi
function print_table_header {
  printf "\n%25s\t%12s\t%12s\t%12s\t%15s\n" "Host" "Installed" "Tag" "Release" "Action"
  echo "  ---------------------------------------------------------------------------------------------------------------------------------"
}

print_table_header

for line in `cat $CONFIG | grep -v '^#'`
do
  HOST=$(echo $line | cut -d "," -f 1)
  KEY=$(echo $line | cut -d "," -f 2)
  RESP=$(/usr/bin/curl -s  -H "Authorization: ${KEY}"  -H "Accept: application/json"  -H "Content-type: application/json"  https://${HOST}/servers/getVersion)
  VERSION_RUNNING=$( echo $RESP |jq -r ".[]"|head -n1 )
  VERSION_RUNNING="${VERSION_RUNNING%%[[:cntrl:]]}"
  if [[ ! $VERSION_RUNNING ]]
  then
      VERSION_RUNNING="n/a"
  fi

  printf "%25s\t%12s\t%12s\t%12s" ${HOST} ${VERSION_RUNNING} ${VERSION_TAG} ${VERSION_RELEASE}
  if [[ ${VERSION_RUNNING} == ${VERSION_RELEASE} || ${VERSION_RUNNING} == ${VERSION_TAG} ]]
  then
    echo -e "  => no update required"
  else
    echo -en "  => The installed version is outdated. Update now? (y/n/c): "
    read -r -s -n 1 input
    echo -n $input
    case "$input" in
		"y")
			echo " Updating server ${HOST}"
            update_server $HOST $KEY
            print_table_header
			;;
		"n")
            echo " (not updating)"
			;;
		"c")
			echo -e " \n  Cancelling the process"
			exit 1
			;;
	esac
  fi
done


