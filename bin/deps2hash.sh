#!/bin/sh
# Because I am LAZY
echo "PREREQ_PM => {"
git grep -P 'use \S+;' | sed -e 's/^.*:use //g;s/[(|)|;]//g' | grep -vP 'strict|warnings' | sort | uniq | sed -e 's/\(.*\)/"\1"/;s/$/ => "0",/'
echo "}"
