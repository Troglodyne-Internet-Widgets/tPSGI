#!/bin/sh

LOG=$(tpsgi-config --custom_log)

if [ -f $LOG ]
then
    grep 'starman:' $LOG

touch warnings.log
FSZ=$(stat --printf "%s" warnings.log)
grep -oP 'starman:\s+.*' $LOG >> warnings.log
echo "$(sort < warnings.log | uniq)" > warnings.log
NEWSZ=$(stat --printf "%s" warnings.log)

if [ $FSZ != $NEWSZ ]
then
    echo "New warning from tPSGI, investigate $LOG!"
    cat warnings.log
fi

fi
