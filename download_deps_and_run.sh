#!/bin/sh
CURDIR=$(pwd)
cd $HOME
mkdir local-lib; /bin/true
mkdir perl5; /bin/true
cd local-lib
curl https://cpan.metacpan.org/authors/id/H/HA/HAARG/local-lib-2.000029.tar.gz > locallib.tar.gz
tar --one-top-level=src --strip-components=1 -zxf locallib.tar.gz
cd src
perl Makefile.PL --bootstrap
cd ../..
eval "$(perl -I$HOME/perl5/lib/perl5 -Mlocal::lib)"
perl -Ilocal-lib/src/lib -MCPAN -Mlocal::lib -e 'CPAN::install(qw{Starman Plack::MIME IO::Compress::Gzip Time::HiRes Date::Format Sys::Hostname Plack::MIME Mojo::File DateTime::Format::HTTP Time::HiRes Log::Dispatch Log::Dispatch::Screen Log::Dispatch::FileRotate HTTP::Parser::XS})';
cd $CURDIR
perl -I~/perl5/lib/perl5 ~/perl5/bin/starman –port 7575 perl-static-file-server.pl
