#!/bin/bash
set -e

REPLICA_SET_NAME=${REPLICA_SET_NAME:=rs0}
USERNAME=${USERNAME:=dev}
PASSWORD=${PASSWORD:=dev}


function waitForMongo {
    port=$1
    user=$2
    pass=$3
    n=0
    until [ $n -ge 20 ]
    do
        if [ -z "$user" ]; then
            mongo admin --quiet --port $port --eval "db" && break
        else
            echo "trying: $port $user $pass"
            mongo admin --quiet --port $port -u $user -p $pass --eval "db" && break
        fi
        n=$[$n+1]
        sleep 2
    done
}

if [ ! "$(ls -A /data/db1)" ]; then
    mkdir /data/db1
    mkdir /data/db2
    mkdir /data/db3

    mongod --dbpath /data/db1 &
    MONGO_PID=$!

    waitForMongo 27017

    echo "CREATING USER ACCOUNT"
    mongo admin --eval "db.createUser({ user: '$USERNAME', pwd: '$PASSWORD', roles: ['root', 'restore', 'readWriteAnyDatabase', 'dbAdminAnyDatabase'] })"

    echo "KILLING MONGO"
    kill $MONGO_PID
    wait $MONGO_PID
fi

echo "WRITING KEYFILE"

openssl rand -base64 741 > /var/mongo_keyfile
chown mongodb /var/mongo_keyfile
chmod 600 /var/mongo_keyfile

if [ -f "/data/db/pre_start.sh" ]; then
  echo "RUNNING PRE START SCRIPT"

  bash /data/db/pre_start.sh
fi

echo "STARTING CLUSTER"

mongod --bind_ip_all --port 27003 --dbpath /data/db3 --auth --replSet $REPLICA_SET_NAME --keyFile /var/mongo_keyfile  &
DB3_PID=$!
mongod --bind_ip_all --port 27002 --dbpath /data/db2 --auth --replSet $REPLICA_SET_NAME --keyFile /var/mongo_keyfile  &
DB2_PID=$!
mongod --bind_ip_all --port 27001 --dbpath /data/db1 --auth --replSet $REPLICA_SET_NAME --keyFile /var/mongo_keyfile  &
DB1_PID=$!

waitForMongo 27001 $USERNAME $PASSWORD
waitForMongo 27002
waitForMongo 27003

if [ -f "/data/db/pre_configuration.sh" ]; then
  echo "RUNNING PRE CONFIGURATION SCRIPT"

  bash /data/db/pre_configuration.sh
fi

echo "CONFIGURING REPLICA SET"
CONFIG="{ _id: '$REPLICA_SET_NAME', members: [{_id: 0, host: 'localhost:27001', priority: 2 }, { _id: 1, host: 'localhost:27002' }, { _id: 2, host: 'localhost:27003' } ]}"
mongo admin --port 27001 -u $USERNAME -p $PASSWORD --eval "db.runCommand({ replSetInitiate: $CONFIG })"

waitForMongo 27002 $USERNAME $PASSWORD
waitForMongo 27003 $USERNAME $PASSWORD

mongo admin --port 27001 -u $USERNAME -p $PASSWORD --eval "db.runCommand({ setParameter: 1, quiet: 1 })"
mongo admin --port 27002 -u $USERNAME -p $PASSWORD --eval "db.runCommand({ setParameter: 1, quiet: 1 })"
mongo admin --port 27003 -u $USERNAME -p $PASSWORD --eval "db.runCommand({ setParameter: 1, quiet: 1 })"

echo "REPLICA SET ONLINE"

if [ -f "/data/db/post_start.sh" ]; then
  echo "RUNNING POST START SCRIPT"

  bash /data/db/post_start.sh
fi

trap 'echo "KILLING"; kill $DB1_PID $DB2_PID $DB3_PID; wait $DB1_PID; wait $DB2_PID; wait $DB3_PID' SIGINT SIGTERM EXIT

wait $DB1_PID
wait $DB2_PID
wait $DB3_PID