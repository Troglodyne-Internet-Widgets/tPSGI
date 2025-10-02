#!/bin/bash

# Make sure this is referring to the right perl env
source .bashrc

USERNAME=$(bin/tpsgi-config --user)
[[ -z $USERNAME ]] && USERNAME=$USER
echo "tPSGI running as user $USERNAME"

[[ -e run/tpsgi.pid ]] && sudo pkill -F run/tpsgi.pid

# Bind the various dirs we need for chroot to work
readarray -t BIND_DIRS <<< $(bin/tpsgi-config --binds)
for bind in "${BIND_DIRS[@]}"; do
    if [[ -z $bind ]]; then
        continue;
    fi;
    bn=$(basename $bind)
    to_bind=$(pwd)/$bn;
    if [[ -d $bind ]]; then
        echo "Bind $bind to $to_bind";
        mkdir -p $to_bind;
        [[ ! $(mountpoint -q $to_bind) ]] && mount --bind $bind $to_bind
    else
        echo "Refusing to bind nonexistant mountpoint $bind to $bn!"
        exit 1;
    fi;
done

# We should obey the PATH set by this user, whose homedir is right here, ideally.
bin/tpsgi --listen run/tpsgi.sock --workers 20 --user "$USERNAME" --daemonize --pid run/tpsgi.pid --chroot $(pwd)

if [ $? ]
then
    echo "Could not start service!"
    exit 1;
fi

# Wait until the socket file is ready
until [ -e run/tpsgi.sock ]
do
    echo "Waiting for sock to be ready..."
    sleep 1
done

# Fix ownership of socket so nginx can see it
sudo chown $USERNAME:www-data run/tpsgi.sock
sudo chmod 0770 run/tpsgi.sock

echo "tPSGI running as PID "`cat run/tpsgi.pid`
