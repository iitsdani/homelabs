#!/bin/sh
set -eu

for directory in cert db_cloud db_local etc extcmd log uploads; do
    if [ ! -d "/data/$directory" ]; then
        cp -a "/usr/share/powermaster-defaults/$directory" "/data/$directory"
    fi
done

mkdir -p /data/preferences
export INSTALL4J_ADD_VM_PARAMS="${INSTALL4J_ADD_VM_PARAMS:-} -Djava.util.prefs.userRoot=/data/preferences"

exec "$@"
