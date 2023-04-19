# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.
#
# OpenCRVS is also distributed under the terms of the Civil Registration
# & Healthcare Disclaimer located at http://opencrvs.org/license.
#
# Copyright (C) The OpenCRVS Authors. OpenCRVS and the OpenCRVS
# graphic logo are (registered/a) trademark(s) of Plan International.

#------------------------------------------------------------------------------------------------------------------
# By default OpenCRVS saves a backup of all data on a cron job every day in case of an emergency data loss incident
# This cron job is already configured in the Ansible playbook.yml in the infrastructure > server-setup directory.
# Change SSH connection settings and IPs to suit your deployment, and re-run the Ansible script to update.
# A version string i.e. 'v1.0.1' can also be provided to the script to be appended to the filenames
#------------------------------------------------------------------------------------------------------------------
set -e

print_usage_and_exit () {
    echo 'Usage: ./emergency-backup-metadata.sh SSH_USER SSH_HOST SSH_PORT PRODUCTION_IP REMOTE_DIR REPLICAS VERSION'
    echo "Script must receive SSH details and a target directory of a remote server to copy backup files to."
    echo "Optionally a VERSION i.e. 'v1.0.1' can be provided to be appended to the backup file labels"
    echo "7 days of backup data will be retained in the manager node"
    echo ""
    echo "If your MongoDB is password protected, an admin user's credentials can be given as environment variables:"
    echo "MONGODB_ADMIN_USER=your_user MONGODB_ADMIN_PASSWORD=your_pass"
    echo ""
    echo "If your Elasticsearch is password protected, an admin user's credentials can be given as environment variables:"
    echo "ELASTICSEARCH_ADMIN_USER=your_user ELASTICSEARCH_ADMIN_PASSWORD=your_pass"
    exit 1
}

if [ -z "$1" ] ; then
    echo "Error: Argument for the SSH_USER is required in position 1."
    print_usage_and_exit
fi
if [ -z "$2" ] ; then
    echo "Error: Argument for the SSH_HOST is required in position 2."
    print_usage_and_exit
fi
if [ -z "$3" ] ; then
    echo "Error: Argument for the SSH_PORT is required in position 3."
    print_usage_and_exit
fi
if [ -z "$4" ] ; then
    echo "Error: Argument for the PRODUCTION_IP is required in position 4."
    print_usage_and_exit
fi
if [ -z "$5" ] ; then
    echo "Error: Argument for the REMOTE_DIR is required in position 5."
    print_usage_and_exit
fi
if [ -z "$6" ] ; then
    echo "Error: Argument for the REPLICAS is required in position 6."
    print_usage_and_exit
fi

# Host and directory where backups will be remotely saved
#--------------------------------------------------------
SSH_USER=$1
SSH_HOST=$2
SSH_PORT=$3
PRODUCTION_IP=$4
REMOTE_DIR=$5
REPLICAS=$6
VERSION=$7

# In this example, we load the MONGODB_ADMIN_USER, MONGODB_ADMIN_PASSWORD, ELASTICSEARCH_ADMIN_USER & ELASTICSEARCH_ADMIN_PASSWORD database access secrets from a file.
# We recommend that the secrets are served via a secure API from a Hardware Security Module
source /data/secrets/opencrvs.secrets

# Select docker network and replica set in production
#----------------------------------------------------
if [ "$REPLICAS" = "0" ]; then
  HOST=mongo1
  NETWORK=opencrvs_default
  echo "Working with no replicas"
elif [ "$REPLICAS" = "1" ]; then
  HOST=rs0/mongo1
  NETWORK=opencrvs_overlay_net
  echo "Working with 1 replica"
elif [ "$REPLICAS" = "3" ]; then
  HOST=rs0/mongo1,mongo2,mongo3
  NETWORK=opencrvs_overlay_net
  echo "Working with 3 replicas"
elif [ "$REPLICAS" = "5" ]; then
  HOST=rs0/mongo1,mongo2,mongo3,mongo4,mongo5
  NETWORK=opencrvs_overlay_net
  echo "Working with 5 replicas"
else
  echo "Script must be passed an understandable number of replicas: 0,1,3 or 5"
  exit 1
fi

mongo_credentials() {
  if [ ! -z ${MONGODB_ADMIN_USER+x} ] || [ ! -z ${MONGODB_ADMIN_PASSWORD+x} ]; then
    echo "--username $MONGODB_ADMIN_USER --password $MONGODB_ADMIN_PASSWORD --authenticationDatabase admin";
  else
    echo "";
  fi
}

elasticsearch_host() {
  if [ ! -z ${ELASTICSEARCH_ADMIN_USER+x} ] || [ ! -z ${ELASTICSEARCH_ADMIN_PASSWORD+x} ]; then
    echo "$ELASTICSEARCH_ADMIN_USER:$ELASTICSEARCH_ADMIN_PASSWORD@elasticsearch:9200";
  else
    echo "elasticsearch:9200";
  fi
}

# Today's date is used for filenames if VERSION is not provided
#-----------------------------------
BACKUP_DATE=$(date +%Y-%m-%d)

# Backup Hearth, OpenHIM, User, Application-config and any other service related Mongo databases into a mongo sub folder
#---------------------------------------------------------------------------------------------
docker run --rm -v /data/backups/mongo:/data/backups/mongo --network=$NETWORK mongo:4.4 bash \
 -c "mongodump $(mongo_credentials) --host $HOST -d hearth-dev --gzip --archive=/data/backups/mongo/hearth-dev-${VERSION:-$BACKUP_DATE}.gz"
docker run --rm -v /data/backups/mongo:/data/backups/mongo --network=$NETWORK mongo:4.4 bash \
 -c "mongodump $(mongo_credentials) --host $HOST -d openhim-dev --gzip --archive=/data/backups/mongo/openhim-dev-${VERSION:-$BACKUP_DATE}.gz"
docker run --rm -v /data/backups/mongo:/data/backups/mongo --network=$NETWORK mongo:4.4 bash \
 -c "mongodump $(mongo_credentials) --host $HOST -d user-mgnt --gzip --archive=/data/backups/mongo/user-mgnt-${VERSION:-$BACKUP_DATE}.gz"
docker run --rm -v /data/backups/mongo:/data/backups/mongo --network=$NETWORK mongo:4.4 bash \
 -c "mongodump $(mongo_credentials) --host $HOST -d application-config --gzip --archive=/data/backups/mongo/application-config-${VERSION:-$BACKUP_DATE}.gz"
docker run --rm -v /data/backups/mongo:/data/backups/mongo --network=$NETWORK mongo:4.4 bash \
 -c "mongodump $(mongo_credentials) --host $HOST -d metrics --gzip --archive=/data/backups/mongo/metrics-${VERSION:-$BACKUP_DATE}.gz"
docker run --rm -v /data/backups/mongo:/data/backups/mongo --network=$NETWORK mongo:4.4 bash \
 -c "mongodump $(mongo_credentials) --host $HOST -d webhooks --gzip --archive=/data/backups/mongo/webhooks-${VERSION:-$BACKUP_DATE}.gz"

# Register backup folder as an Elasticsearch repository for backing up the search data
#-------------------------------------------------------------------------------------
docker run --rm --network=$NETWORK appropriate/curl curl -X PUT -H "Content-Type: application/json;charset=UTF-8" "http://$(elasticsearch_host)/_snapshot/ocrvs" -d '{ "type": "fs", "settings": { "location": "/data/backups/elasticsearch", "compress": true }}'

sleep 10
# Backup Elasticsearch as a set of snapshot files into an elasticsearch sub folder
#---------------------------------------------------------------------------------
docker run --rm --network=$NETWORK appropriate/curl curl -X PUT -H "Content-Type: application/json;charset=UTF-8" "http://$(elasticsearch_host)/_snapshot/ocrvs/snapshot_${VERSION:-$BACKUP_DATE}?wait_for_completion=true&pretty" -d '{ "indices": "ocrvs" }'

# Get the container ID and host details of any running InfluxDB container, as the only way to backup is by using the Influxd CLI inside a running opencrvs_metrics container
#---------------------------------------------------------------------------------------------------------------------------------------------------------------------------
INFLUXDB_CONTAINER_ID=`echo $(docker service ps --no-trunc -f "desired-state=running" opencrvs_influxdb) | awk '{print $11}'`
INFLUXDB_CONTAINER_NAME=`echo $(docker service ps --no-trunc -f "desired-state=running" opencrvs_influxdb) | awk '{print $12}'`
INFLUXDB_HOSTNAME=`echo $(docker service ps -f "desired-state=running" opencrvs_influxdb) | awk '{print $14}'`
INFLUXDB_HOST=$(docker node inspect --format '{{.Status.Addr}}' "$HOSTNAME")
INFLUXDB_SSH_USER=${INFLUXDB_SSH_USER:-root}

# If required, SSH into the node running the opencrvs_metrics container and backup the metrics data into an influxdb subfolder
#-----------------------------------------------------------------------------------------------------------------------------

OWN_IP=$(hostname -I | cut -d' ' -f1)
if [[ "$OWN_IP" = "$INFLUXDB_HOST" ]]; then
  echo "Backing up Influx on own node"
  docker exec $INFLUXDB_CONTAINER_NAME.$INFLUXDB_CONTAINER_ID influxd backup -portable -database ocrvs /home/user/${VERSION:-$BACKUP_DATE}
  docker cp $INFLUXDB_CONTAINER_NAME.$INFLUXDB_CONTAINER_ID:/home/user/${VERSION:-$BACKUP_DATE} /data/backups/influxdb/${VERSION:-$BACKUP_DATE}
else
  echo "Backing up Influx on other node $INFLUXDB_HOST"
  rsync -a -r --ignore-existing --progress --rsh="ssh -p$SSH_PORT" /data/backups/influxdb $INFLUXDB_SSH_USER@$INFLUXDB_HOST:/data/backups/influxdb
  ssh $INFLUXDB_SSH_USER@$INFLUXDB_HOST "docker exec $INFLUXDB_CONTAINER_NAME.$INFLUXDB_CONTAINER_ID influxd backup -portable -database ocrvs /home/user/${VERSION:-$BACKUP_DATE}"
  ssh $INFLUXDB_SSH_USER@$INFLUXDB_HOST "docker cp $INFLUXDB_CONTAINER_NAME.$INFLUXDB_CONTAINER_ID:/home/user/${VERSION:-$BACKUP_DATE} /data/backups/influxdb/${VERSION:-$BACKUP_DATE}"
  echo "Replacing backup for influxdb on manager node with new backup"
  rsync -a -r --ignore-existing --progress --rsh="ssh -p$SSH_PORT" $INFLUXDB_SSH_USER@$INFLUXDB_HOST:/data/backups/influxdb /data/backups/influxdb
fi

# Backup Minio
cd /data/minio && tar -zcvf /data/backups/minio/ocrvs-${VERSION:-$BACKUP_DATE}.tar.gz * && cd /

# Backup Metabase
cd /data/metabase && tar -zcvf /data/backups/metabase/ocrvs-${VERSION:-$BACKUP_DATE}.tar.gz * && cd /

# Backup VSExport
cd /data/vsexport && tar -zcvf /data/backups/vsexport/ocrvs-${VERSION:-$BACKUP_DATE}.tar.gz * && cd /

# Copy the backups to an offsite server in production
#----------------------------------------------------
if [[ "$OWN_IP" = "$PRODUCTION_IP" || "$OWN_IP" = "$(dig $PRODUCTION_IP +short)" ]]; then
  script -q -c "rsync -a -r --progress --rsh='ssh -p$SSH_PORT' /data/backups/elasticsearch/ $SSH_USER@$SSH_HOST:$REMOTE_DIR/elasticsearch" && echo "Copied elasticsearch backup files to remote server."
  script -q -c "rsync -a -r --ignore-existing --progress --rsh='ssh -p$SSH_PORT' /data/backups/minio/${VERSION:-$BACKUP_DATE} $SSH_USER@$SSH_HOST:$REMOTE_DIR/minio" && echo "Copied minio backup files to remote server."
  script -q -c "rsync -a -r --ignore-existing --progress --rsh='ssh -p$SSH_PORT' /data/backups/metabase/${VERSION:-$BACKUP_DATE} $SSH_USER@$SSH_HOST:$REMOTE_DIR/metabase" && echo "Copied Metabase backup files to remote server."
  script -q -c "rsync -a -r --ignore-existing --progress --rsh='ssh -p$SSH_PORT' /data/backups/influxdb/${VERSION:-$BACKUP_DATE} $SSH_USER@$SSH_HOST:$REMOTE_DIR/influxdb" && echo "Copied influx backup files to remote server."
  script -q -c "rsync -a -r --ignore-existing --progress --rsh='ssh -p$SSH_PORT' /data/backups/mongo/hearth-dev-${VERSION:-$BACKUP_DATE}.gz $SSH_USER@$SSH_HOST:$REMOTE_DIR/mongo" && echo "Copied hearth backup files to remote server."
  script -q -c "rsync -a -r --ignore-existing --progress --rsh='ssh -p$SSH_PORT' /data/backups/mongo/user-mgnt-${VERSION:-$BACKUP_DATE}.gz $SSH_USER@$SSH_HOST:$REMOTE_DIR/mongo" && echo "Copied user backup files to remote server."
  script -q -c "rsync -a -r --ignore-existing --progress --rsh='ssh -p$SSH_PORT' /data/backups/mongo/openhim-dev-${VERSION:-$BACKUP_DATE}.gz $SSH_USER@$SSH_HOST:$REMOTE_DIR/mongo" && echo "Copied openhim backup files to remote server."
  script -q -c "rsync -a -r --ignore-existing --progress --rsh='ssh -p$SSH_PORT' /data/backups/mongo/application-config-${VERSION:-$BACKUP_DATE}.gz $SSH_USER@$SSH_HOST:$REMOTE_DIR/mongo" && echo "Copied application-config backup files to remote server."
  script -q -c "rsync -a -r --ignore-existing --progress --rsh='ssh -p$SSH_PORT' /data/backups/mongo/metrics-${VERSION:-$BACKUP_DATE}.gz $SSH_USER@$SSH_HOST:$REMOTE_DIR/mongo" && echo "Copied metrics backup files to remote server."
  script -q -c "rsync -a -r --ignore-existing --progress --rsh='ssh -p$SSH_PORT' /data/backups/mongo/webhooks-${VERSION:-$BACKUP_DATE}.gz $SSH_USER@$SSH_HOST:$REMOTE_DIR/mongo" && echo "Copied webhooks backup files to remote server."
fi

# Cleanup any old backups from influx or mongo. Keep previous 7 days of data and all elastic data
# Elastic snapshots require a random selection of files in the data/backups/elasticsearch/indices
# folder
#------------------------------------------------------------------------------------------------
find /data/backups/influxdb -mtime +7 -exec rm {} \;
find /data/backups/mongo -mtime +7 -exec rm {} \;
find /data/backups/minio -mtime +7 -exec rm {} \;
find /data/backups/metabase -mtime +7 -exec rm {} \;
find /data/backups/vsexport -mtime +7 -exec rm {} \;
