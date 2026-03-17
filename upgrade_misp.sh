#!/bin/bash

# upgrade all MISP servers stored in config.csv
# config file needed (config.csv)
# fields:
# server_name,API_key
# 2024-03 - 2026 Sascha Rommelfangen, CIRCL, LHC

function update_server { 
  HOST="$1"
  KEY="$2"
  ../matrix.sh/matrix.sh "Currently updating MISP server $HOST. Cross your fingers!"
  RESULT=$(curl -s -d '[]' -H "Authorization: $KEY" -H "Accept: application/json" -H "Content-type: application/json" -X POST https://$HOST/servers/update )
  #echo "$RESULT"
  if [[ $(echo $RESULT|jq|egrep -e "status\"\:|Update failed"|grep -v 0) ]]
  then
      echo -en "  => Something went wrong updating MISP. See the output? (y/n): "
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
      echo "  => Updated MISP successfully or no update available"
  fi
  echo "Updating JSON"
  RESULT=$(curl -s -d '[]' -H "Authorization: $KEY" -H "Accept: application/json" -H "Content-type: application/json" -X POST https://$HOST/servers/updateJSON/ )
  if [[ $(echo $RESULT|jq|egrep -e "status\"\:|Update failed"|grep -v 0) ]]
  then
      echo -en "  => Something went wrong updating JSON. See the output? (y/n): "
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
      echo "  => Updated JSON successfully or no update available"
  fi
}

# get release version
VERSION_RELEASES=$( curl -s https://github.com/MISP/MISP/releases |ggrep -oP '/MISP/MISP/releases/expanded_assets/\Kv[0-9]+\.[0-9]+\.[0-9]+' | rev | cut -d "/" -f 1|rev|cut -d "v" -f 2 )
VERSION_RELEASE=""
# get tag version
VERSION_TAGS=$( curl -s https://github.com/MISP/MISP/tags/ |grep /MISP/MISP/releases/tag/|head -n 18|ggrep -oP '/MISP/MISP/releases/tag/\Kv[0-9]+\.[0-9]+\.[0-9]+' | rev|cut -d "<" -f 3|cut -d ">" -f 1|rev|cut -d "v" -f 2 )
VERSION_TAG=""
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
  if [[ $(echo $RESP|egrep -e "Authentication failed") ]]
  then
    printf "%25s\t%85s\n" ${HOST} " => [!] Authentication key is incorrect!"
  else 
    VERSION_RUNNING=$( echo $RESP |jq -r ".[]"|head -n1 )
    VERSION_RUNNING="${VERSION_RUNNING%%[[:cntrl:]]}"
    if [[ ! $VERSION_RUNNING ]]
    then
      VERSION_RUNNING="n/a"
    fi

    if [[ $VERSION_RUNNING =~ 2\.4\. ]]
    then
        VERSION_TAG=$( echo "$VERSION_TAGS" | egrep "2.4.*" | cut -d " " -f 2 | head -n 1)
        VERSION_RELEASE=$( echo "$VERSION_RELEASES" | egrep "2.4.*" | cut -d " " -f 2 | head -n 1)
    else
        VERSION_TAG=$( echo "$VERSION_TAGS" | egrep "2.5.*" | cut -d " " -f 1 | head -n 1)
        VERSION_RELEASE=$( echo "$VERSION_RELEASES" | egrep "2.5.*" | cut -d " " -f 1 | head -n 1)
    fi
    printf "%25s\t%12s\t%12s\t%12s" ${HOST} ${VERSION_RUNNING} ${VERSION_TAG} ${VERSION_RELEASE}
    if [[ ${VERSION_RUNNING} == ${VERSION_TAG} ]]
        # || ${VERSION_RUNNING} == ${VERSION_RELEASE} ]]
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
  fi
done


