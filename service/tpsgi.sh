#!/bin/bash

USERNAME=$(bin/tpsgi-config --user)
[[ -z $USERNAME ]] && USERNAME=$USER
echo "tPSGI running as user $USERNAME"

EGID=$(id -nu)
GROUP=$(bin/tpsgi-config --http_user)
[[ -z $GROUP ]] && GROUP=$EGID
echo "tPSGI running with EGID $GROUP";

[[ -e run/tpsgi.pid ]] && sudo pkill -F run/tpsgi.pid

# Hand the application whatever systemd put in the credential store.  It has to
# happen here: tarbaby chroots the workers into this directory, and the store is
# a ramdisk at /run/credentials which is not inside it.  So the file is read
# while there is still a path to it, and what was in it goes on in the
# environment, which survives the chroot.
#
# The application is expected to take it back out of its own environment as it
# starts, so that nothing it forks later inherits it.
if [[ -n ${CREDENTIALS_DIRECTORY:-} && -r "$CREDENTIALS_DIRECTORY/tpsgi-vault" ]]; then
    export TPSGI_VAULT_KEY=$(cat "$CREDENTIALS_DIRECTORY/tpsgi-vault")
    echo "Loaded the tpsgi-vault credential"
fi

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
bin/tarbaby --listen run/tpsgi.sock --workers 20 --user "$USERNAME" --group "$GROUP" --daemonize --pid run/tpsgi.pid --chroot $(pwd) bin/tpsgi

if [ $? -ne 0 ]
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
