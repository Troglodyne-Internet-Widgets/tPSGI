#!/usr/bin/env perl

# Tests for TPSGI route matching behavior.
# Verifies that exact and regex routes dispatch to the correct handler,
# and that handler hashrefs (at odd indices in @routes) are never
# accidentally matched as if they were route patterns.

use strict;
use warnings;

use Test::More;
use File::Temp qw{tempdir};

use lib 't/lib';
use TPSGITestStubs;
use FindBin::libs;

use TPSGI;

my $tmpdir  = tempdir(CLEANUP => 1);
my $logfile = "$tmpdir/tpsgi.log";

my $user     = scalar getpwuid($>);
my $http_grp = (getgrgid($)))[0];

# Build a minimal TPSGI object without loading any router files.
# We inject routes directly to avoid needing real .pm files on disk.
sub _make_tpsgi {
    my %extra = @_;

    # new() loads router files from disk. Bypass that by blessing directly
    # after setting up the minimal required state.
    my $self = bless {
        user       => $user,
        http_user  => $http_grp,
        tpsgi_dir  => $tmpdir,
        basedir    => '.',
        log_dir    => $tmpdir,
        log_name   => $logfile,
        verbose    => 0,
        autoreload => 0,
        indices    => [qw{index.html index.htm index.cgi}],
        callbacks  => [],
        routes     => [],
        aliases    => {},
        ip         => '127.0.0.1',
        gid        => scalar(getgrnam($http_grp)),
        loggers    => [],
        %extra,
    }, 'TPSGI';

    return $self;
}

# Build a minimal PSGI env for a GET request to $path.
sub _env {
    my ($path) = @_;
    return {
        REQUEST_METHOD    => 'GET',
        REQUEST_URI       => $path,
        PATH_INFO         => $path,
        HTTP_HOST         => 'localhost',
        REMOTE_ADDR       => '127.0.0.1',
        'psgi.streaming'  => 0,
        'psgi.errors'     => \*STDERR,
        'psgi.url_scheme' => 'http',
        QUERY_STRING      => '',
        CONTENT_TYPE      => 'text/html',
        CONTENT_LENGTH    => 0,
    };
}

# ---- Exact route matching ----

subtest 'exact route: correct handler dispatched' => sub {
    my $dispatched = 0;

    my $handler = {
        method    => 'GET',
        callbacks => { '*' => sub { $dispatched++; return [200, ['Content-Type' => 'text/plain', 'Content-Length' => 2], ['ok']] } },
        pattern   => '/hello',
    };

    my $tpsgi = _make_tpsgi();
    $tpsgi->{routes} = ['/hello', $handler];

    my $resp = TPSGI::_app($tpsgi, _env('/hello'));
    ok(ref $resp eq 'ARRAY', 'got array response');
    is($resp->[0], 200, 'status 200');
    is($dispatched, 1,  'handler called exactly once');
};

subtest 'exact route: non-matching path falls through to 404' => sub {
    my $handler = {
        method    => 'GET',
        callbacks => { '*' => sub { return [200, ['Content-Type' => 'text/plain', 'Content-Length' => 2], ['ok']] } },
        pattern   => '/hello',
    };

    my $tpsgi = _make_tpsgi();
    $tpsgi->{routes} = ['/hello', $handler];

    my $resp = TPSGI::_app($tpsgi, _env('/goodbye'));
    ok(ref $resp eq 'ARRAY', 'got array response');
    is($resp->[0], 404, 'unmatched path -> 404');
};

subtest 'exact route: handler hashref at odd index is not matched as pattern' => sub {
    # This catches the bug where the loop iterated over odd indices too.
    # A handler hashref stringified to HASH(0x...) should never match a real path.
    my $handler = {
        method    => 'GET',
        callbacks => { '*' => sub { return [200, ['Content-Type' => 'text/plain', 'Content-Length' => 2], ['ok']] } },
        pattern   => '/real',
    };

    my $tpsgi = _make_tpsgi();
    $tpsgi->{routes} = ['/real', $handler];

    # Fabricate a path that looks like a stringified hashref. Should NOT match.
    my $fake_path = '/' . ref($handler) . '(0x1234)';
    my $resp = TPSGI::_app($tpsgi, _env($fake_path));
    is($resp->[0], 404, 'stringified hashref path does not match any route');
};

# ---- Regex route matching ----

subtest 'regex route: captures work correctly' => sub {
    my $captured_name;

    my $handler = {
        method    => 'GET',
        captures  => ['name'],
        callbacks => { '*' => sub {
            my ($self, $q) = @_;
            $captured_name = $q->{name};
            return [200, ['Content-Type' => 'text/plain', 'Content-Length' => 2], ['ok']];
        }},
        pattern   => '/user/(\w+)',
    };

    my $tpsgi = _make_tpsgi();
    $tpsgi->{routes} = ['/user/(\w+)', $handler];

    my $resp = TPSGI::_app($tpsgi, _env('/user/alice'));
    is($resp->[0], 200,     'matched regex route -> 200');
    is($captured_name, 'alice', 'capture group extracted correctly');
};

subtest 'regex route: multiple routes, correct one chosen' => sub {
    my $which_route = '';

    my $h1 = {
        method    => 'GET',
        callbacks => { '*' => sub { $which_route = 'h1'; [200, ['Content-Type' => 'text/plain', 'Content-Length' => 2], ['ok']] } },
        pattern   => '/api/v1/(\w+)',
    };
    my $h2 = {
        method    => 'GET',
        callbacks => { '*' => sub { $which_route = 'h2'; [200, ['Content-Type' => 'text/plain', 'Content-Length' => 2], ['ok']] } },
        pattern   => '/api/v2/(\w+)',
    };

    my $tpsgi = _make_tpsgi();
    $tpsgi->{routes} = ['/api/v1/(\w+)', $h1, '/api/v2/(\w+)', $h2];

    TPSGI::_app($tpsgi, _env('/api/v2/foo'));
    is($which_route, 'h2', 'v2 route chosen when requesting /api/v2/foo');

    $which_route = '';
    TPSGI::_app($tpsgi, _env('/api/v1/bar'));
    is($which_route, 'h1', 'v1 route chosen when requesting /api/v1/bar');
};

done_testing;
