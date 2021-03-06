#!/usr/bin/env bash

set -x
# Copyright 2018 The Kubernetes Authors. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

replica_set="$REPLICA_SET"
script_name=${0##*/}

if [[ "$AUTH" == "true" ]]; then
    admin_user="$ADMIN_USER"
    admin_password="$ADMIN_PASSWORD"
    admin_creds=(-u "$admin_user" -p "$admin_password")
    if [[ "$METRICS" == "true" ]]; then
        metrics_user="$METRICS_USER"
        metrics_password="$METRICS_PASSWORD"
    fi
    auth_args=("--auth" "--keyFile=/data/configdb/key.txt")
fi

log() {
    local msg="$1"
    local timestamp
    timestamp=$(date --iso-8601=ns)
    echo "[$timestamp] [$script_name] $msg" >> /work-dir/log.txt
}

shutdown_mongo() {
    if [[ $# -eq 1 ]]; then
        args="timeoutSecs: $1"
    else
        args='force: true'
    fi
    log "Shutting down MongoDB ($args)..."
    mongo admin "${admin_creds[@]}" "${ssl_args[@]}" --eval "db.shutdownServer({$args})"
}

# We'll set an env variable to the desired FQDN. If it isn't set, then we'll discover the FQDN later
my_hostname=$(hostname)
if [[ ${MONGO_FQDN:-} != "" ]]; then
    my_hostname="${my_hostname}.${MONGO_FQDN}"
    my_fqdn="${my_hostname}"
fi

log "Bootstrapping MongoDB replica set member: $my_fqdn"

log "Reading standard input..."
while read -ra line; do
    if [[ $my_fqdn == "" ]] && [[ "${line}" == *"${my_hostname}"* ]]; then
        my_fqdn="$line"
        continue
    fi
    peers=("${peers[@]}" "$line")
done

service_fqdn=${my_fqdn#*.}
public_servie_fqdn=$( echo "$service_fqdn" | cut -d. -f1 )-public.$( echo "$service_fqdn" | cut -d. -f2- )

# Generate the ca cert
ca_crt=/data/configdb/tls.crt
if [ -f "$ca_crt"  ]; then
    log "Generating certificate"
    ca_key=/data/configdb/tls.key
    pem=/work-dir/mongo.pem
    ssl_args=(--ssl --sslCAFile "$ca_crt" --sslPEMKeyFile "$pem")

    # Sample fqdn: mongodb-1.service.namespace.svc.cluster.local
    hostnames_to_add=( 
        $(echo -n "$my_fqdn" | cut -d. -f1 )        # Short hostname: mongodb-1
        $(echo -n "$my_fqdn" | cut -d. -f1-2 )      # Hostname and service: mongodb-1.service
        $(echo -n "$my_fqdn" | cut -d. -f1-3 )      # namespace localized: mongodb-1.service.namespace
        $my_fqdn                                    # Full fqdn: mongodb-1.service.namespace.svc.cluster.local
        $(echo -n "$service_fqdn" | cut -d. -f1 )   # Just service: service
        $(echo -n "$service_fqdn" | cut -d. -f1-2 ) # Namespace localized: service.namespace
        $service_fqdn                               # Full service: service.namespace.svc.cluster.local
        ${PUBLIC_HOSTNAME:-}                        # Public hostname as given in values.yaml
        localhost
        127.0.0.1
    )

# Move into /work-dir
pushd /work-dir

cat >openssl.cnf <<EOL
[req]
req_extensions = v3_req
distinguished_name = req_distinguished_name
[req_distinguished_name]
[ v3_req ]
basicConstraints = CA:FALSE
keyUsage = nonRepudiation, digitalSignature, keyEncipherment
subjectAltName = @alt_names
[alt_names]
$( for h in ${hostnames_to_add[@]}; do printf "DNS.%d = %s\n" $(( ++i )) $h; done )
EOL

    # Generate the certs
    openssl genrsa -out mongo.key 2048
    openssl req -new -key mongo.key -out mongo.csr -subj "/CN=${my_fqdn%%.*}" -config openssl.cnf
    openssl x509 -req -in mongo.csr \
        -CA "$ca_crt" -CAkey "$ca_key" -CAcreateserial \
        -out mongo.crt -days 3650 -extensions v3_req -extfile openssl.cnf

    rm mongo.csr
    cat mongo.crt mongo.key > $pem
    rm mongo.key mongo.crt
fi


log "Peers: ${peers[*]}"

log "Starting a MongoDB instance..."
mongod --config /data/configdb/mongod.conf --dbpath=/data/db --replSet="$replica_set" --port=27017 "${auth_args[@]}" --bind_ip=0.0.0.0 >> /work-dir/log.txt 2>&1 &

log "Waiting for MongoDB to be ready..."
until mongo "${ssl_args[@]}" --eval "db.adminCommand('ping')"; do
    log "Retrying..."
    sleep 2
done

log "Initialized."

# try to find a master and add yourself to its replica set.
for peer in "${peers[@]}"; do
    if mongo admin --host "$peer" "${admin_creds[@]}" "${ssl_args[@]}" --eval "rs.isMaster()" | grep '"ismaster" : true'; then
        log "Found master: $peer"
        log "Adding myself ($my_fqdn) to replica set..."
        mongo admin --host "$peer" "${admin_creds[@]}" "${ssl_args[@]}" --eval "rs.add('$my_fqdn')"

        sleep 3

        log 'Waiting for replica to reach SECONDARY state...'
        until printf '.' && [[ $(mongo admin "${admin_creds[@]}" "${ssl_args[@]}" --quiet --eval "rs.status().myState") == '2' ]]; do
            sleep 1
        done

        log '✓ Replica reached SECONDARY state.'

        # create the metric user if it does not exist
        if [[ "$AUTH" == "true" ]]; then
            if [[ "$METRICS" == "true" ]]; then
                metric_user_count=$(mongo admin --host "$peer" "${admin_creds[@]}" "${ssl_args[@]}" --eval "db.system.users.find({user: '$metrics_user'}).count()" --quiet)
                if [ "$metric_user_count" == "0" ]; then
                    log "Creating clusterMonitor user..."
                    mongo admin --host "$peer" "${admin_creds[@]}" "${ssl_args[@]}" --eval "db.createUser({user: '$metrics_user', pwd: '$metrics_password', roles: [{role: 'clusterMonitor', db: 'admin'}, {role: 'read', db: 'local'}]})"
                fi
            fi
        fi

        shutdown_mongo "60"
        log "Good bye."
        exit 0
    fi
done

# else initiate a replica set with yourself.
if mongo "${ssl_args[@]}" --eval "rs.status()" | grep "no replset config has been received"; then
    log "Initiating a new replica set with myself ($my_fqdn)..."
    mongo "${ssl_args[@]}" --eval "rs.initiate({'_id': '$replica_set', 'members': [{'_id': 0, 'host': '$my_fqdn'}]})"

    sleep 3

    log 'Waiting for replica to reach PRIMARY state...'
    until printf '.' && [[ $(mongo "${ssl_args[@]}" --quiet --eval "rs.status().myState") == '1' ]]; do
        sleep 1
    done

    log '✓ Replica reached PRIMARY state.'

    if [[ "$AUTH" == "true" ]]; then
        log "Creating admin user..."
        mongo admin "${ssl_args[@]}" --eval "db.createUser({user: '$admin_user', pwd: '$admin_password', roles: [{role: 'root', db: 'admin'}]})"
        if [[ "$METRICS" == "true" ]]; then
            log "Creating clusterMonitor user..."
            mongo admin "${admin_creds[@]}" "${ssl_args[@]}" --eval "db.createUser({user: '$metrics_user', pwd: '$metrics_password', roles: [{role: 'clusterMonitor', db: 'admin'}, {role: 'read', db: 'local'}]})"
        fi
    fi

    log "Done."
fi

shutdown_mongo
log "Good bye."
