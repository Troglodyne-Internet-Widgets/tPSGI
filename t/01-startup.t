#!/usr/bin/env perl

use strict;
use warnings;

use Test::More;
use File::Temp qw{tempdir};
use File::Spec;

use lib 't/lib';
use TPSGITestStubs;
use FindBin::libs;

use TPSGI::Startup;

my $tmpdir = tempdir(CLEANUP => 1);

subtest 'get_config returns defaults when no ini file present' => sub {
    local $ENV{HOME} = $tmpdir;

    my %cfg = TPSGI::Startup::get_config();

    is($cfg{verbose},    0,    'verbose defaults to 0');
    is($cfg{autoreload}, 0,    'autoreload defaults to 0');
    is($cfg{basedir},    '.',  'basedir defaults to dot');
    is($cfg{domain},     '',   'domain defaults to empty string');
    is($cfg{user},       '',   'user defaults to empty string');
    is($cfg{http_user},  '',   'http_user defaults to empty string');
    is(ref($cfg{routers}), 'ARRAY', 'routers is an arrayref');
    is(ref($cfg{loggers}), 'ARRAY', 'loggers is an arrayref');
    ok(defined $cfg{tpsgi_dir}, 'tpsgi_dir is set');
    ok(defined $cfg{log_dir},   'log_dir is set');
    ok(defined $cfg{log_name},  'log_name is set');
};

subtest 'get_config reads scalar values from ini file' => sub {
    my $ini = File::Spec->catfile($tmpdir, '.tpsgi.ini');
    open(my $fh, '>', $ini) or die "Cannot write $ini: $!";
    print $fh "[default]\n";
    print $fh "verbose=1\n";
    print $fh "domain=example.com\n";
    print $fh "user=testuser\n";
    print $fh "http_user=nginx\n";
    print $fh "autoreload=1\n";
    close $fh;

    local $ENV{HOME} = $tmpdir;

    my %cfg = TPSGI::Startup::get_config();

    is($cfg{verbose},    1,             'verbose read from ini');
    is($cfg{domain},     'example.com', 'domain read from ini');
    is($cfg{user},       'testuser',    'user read from ini');
    is($cfg{http_user},  'nginx',       'http_user read from ini');
    is($cfg{autoreload}, 1,             'autoreload read from ini');
};

subtest 'get_config log_name uses custom_log when set' => sub {
    my $ini = File::Spec->catfile($tmpdir, '.tpsgi.ini');
    open(my $fh, '>', $ini) or die "Cannot write $ini: $!";
    print $fh "[default]\n";
    print $fh "custom_log=$tmpdir/myapp.log\n";
    close $fh;

    local $ENV{HOME} = $tmpdir;

    my %cfg = TPSGI::Startup::get_config();

    is($cfg{log_name}, "$tmpdir/myapp.log", 'log_name uses custom_log');
};

subtest 'get_config routers accumulates as array' => sub {
    my $ini = File::Spec->catfile($tmpdir, '.tpsgi.ini');
    open(my $fh, '>', $ini) or die "Cannot write $ini: $!";
    print $fh "[default]\n";
    print $fh "routers=lib/Router/Foo.pm\n";
    close $fh;

    local $ENV{HOME} = $tmpdir;

    my %cfg = TPSGI::Startup::get_config();

    is(ref($cfg{routers}), 'ARRAY', 'routers is arrayref');
    is(scalar @{$cfg{routers}}, 1,  'routers has one entry');
    is($cfg{routers}[0], 'lib/Router/Foo.pm', 'correct router path');
};

done_testing;
