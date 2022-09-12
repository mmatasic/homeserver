#!/bin/bash
JAIL=$1
IP=$2

if [ $# -eq 0 ]
  then
    echo "No arguments!"
    echo "usage: unban jail ip"
    exit 1
fi

if [ -z "$1" ]
  then
    echo "No jail specified"
    exit 1
fi

if [ -z "$2" ]
  then
    echo "No IP specified"
    exit 1
fi
sudo docker exec -it swag fail2ban-client set ${JAIL} unbanip ${IP}

