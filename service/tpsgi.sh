#!/bin/bash
HOMEDIR=$(git rev-parse --show-toplevel)
[[ ! -z $HOMEDIR ]] && HOME=$HOMEDIR
echo "Set HOME to $HOME"

cd $HOME
echo "Changed directory to $HOME"

USERNAME=$(bin/tpsgi-config --user)
[[ -z $USERNAME ]] && USERNAME=$USER
echo "tPSGI running as user $USERNAME"

[[ -e run/tpsgi.pid ]] && sudo pkill -F run/tpsgi.pid
source perl5/perlbrew/etc/bashrc

# We should obey the PATH set by this user, whose homedir is right here, ideally. 
PERL=$(sudo -i -u $USERNAME which perl)
STARMAN=$(sudo -i -u $USERNAME which starman)
sudo $PERL $STARMAN www/server.psgi --listen run/tpsgi.sock --workers 20 --user "$USERNAME" --daemonize --pid run/tpsgi.pid --chroot $(pwd)

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
