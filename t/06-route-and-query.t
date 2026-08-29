#!/usr/bin/env perl

# Tests for route() dispatch and extract_query() parameter handling.
# Covers: method validation, content-type dispatch, GET/POST params,
# route captures, data injection, server-timing headers, and HTTP
# error helper responses.

use strict;
use warnings;

use Test::More;
use File::Temp qw{tempdir};
use Time::HiRes qw{gettimeofday};

use lib 't/lib';
use TPSGITestStubs;
use FindBin::libs;

use TPSGI;

my $tmpdir = tempdir(CLEANUP => 1);

my $user     = scalar getpwuid($>);
my $http_grp = (getgrgid($)))[0];

sub _make_tpsgi {
    my %extra = @_;
    return bless {
        user       => $user,
        http_user  => $http_grp,
        tpsgi_dir  => $tmpdir,
        basedir    => '.',
        log_dir    => $tmpdir,
        log_name   => "$tmpdir/tpsgi.log",
        verbose    => 0,
        autoreload => 0,
        indices    => [qw{index.html}],
        callbacks  => [],
        routes     => [],
        aliases    => {},
        ip         => '127.0.0.1',
        gid        => scalar(getgrnam($http_grp)),
        loggers    => [],
        %extra,
    }, 'TPSGI';
}

sub _env {
    my (%extra) = @_;
    return {
        REQUEST_METHOD    => 'GET',
        REQUEST_URI       => '/test',
        PATH_INFO         => '/test',
        HTTP_HOST         => 'localhost',
        REMOTE_ADDR       => '127.0.0.1',
        'psgi.streaming'  => 0,
        'psgi.errors'     => \*STDERR,
        'psgi.url_scheme' => 'http',
        QUERY_STRING      => '',
        CONTENT_TYPE      => 'text/html',
        CONTENT_LENGTH    => 0,
        %extra,
    };
}

sub _start { return [gettimeofday] }

# ---- HTTP error helpers ----

subtest 'notfound returns 404' => sub {
    my $tpsgi = _make_tpsgi();
    my $query = { method => 'GET', fullpath => '/nope', tpsgi => $tpsgi, ip => '127.0.0.1', ua => '', referer => '' };
    my $resp = $tpsgi->notfound($query);
    is($resp->[0], 404, 'notfound -> 404');
};

subtest 'forbidden returns 403' => sub {
    my $tpsgi = _make_tpsgi();
    my $query = { method => 'GET', fullpath => '/secret', tpsgi => $tpsgi, ip => '127.0.0.1', ua => '', referer => '' };
    my $resp = $tpsgi->forbidden($query);
    is($resp->[0], 403, 'forbidden -> 403');
};

subtest 'badrequest returns 400' => sub {
    my $tpsgi = _make_tpsgi();
    my $query = { method => 'GET', fullpath => '/bad', tpsgi => $tpsgi, ip => '127.0.0.1', ua => '', referer => '' };
    my $resp = $tpsgi->badrequest($query);
    is($resp->[0], 400, 'badrequest -> 400');
};

subtest 'error returns 500' => sub {
    my $tpsgi = _make_tpsgi();
    my $query = { method => 'GET', fullpath => '/explode', tpsgi => $tpsgi, ip => '127.0.0.1', ua => '', referer => '' };
    my $resp = $tpsgi->error($query);
    is($resp->[0], 500, 'error -> 500');
};

subtest 'unavailable returns 503' => sub {
    my $tpsgi = _make_tpsgi();
    my $query = { method => 'GET', fullpath => '/down', tpsgi => $tpsgi, ip => '127.0.0.1', ua => '', referer => '' };
    my $resp = $tpsgi->unavailable($query);
    is($resp->[0], 503, 'unavailable -> 503');
};

subtest 'toolong returns 419' => sub {
    my $tpsgi = _make_tpsgi();
    my $query = { method => 'GET', fullpath => '/x' x 3000, tpsgi => $tpsgi, ip => '127.0.0.1', ua => '', referer => '' };
    my $resp = $tpsgi->toolong($query);
    is($resp->[0], 419, 'toolong -> 419');
};

# ---- route: method validation ----

subtest 'route: wrong HTTP method returns 400' => sub {
    my $handler = {
        method    => 'GET',
        callbacks => { '*' => sub { [200, ['Content-Type' => 'text/plain', 'Content-Length' => 2], ['ok']] } },
        pattern   => '/api',
    };

    my $tpsgi = _make_tpsgi();
    $tpsgi->{routes} = ['/api', $handler];

    my $env = _env(REQUEST_METHOD => 'DELETE', PATH_INFO => '/api', REQUEST_URI => '/api');
    my $resp = TPSGI::_app($tpsgi, $env);
    is($resp->[0], 400, 'DELETE on GET-only route -> 400');
};

subtest 'route: HEAD method allowed on GET route' => sub {
    my $handler = {
        method    => 'GET',
        callbacks => { '*' => sub { [200, ['Content-Type' => 'text/plain', 'Content-Length' => 2], ['ok']] } },
        pattern   => '/headtest',
    };

    my $tpsgi = _make_tpsgi();
    $tpsgi->{routes} = ['/headtest', $handler];

    my $env = _env(REQUEST_METHOD => 'HEAD', PATH_INFO => '/headtest', REQUEST_URI => '/headtest');
    my $resp = TPSGI::_app($tpsgi, $env);
    is($resp->[0], 200, 'HEAD allowed on GET route');
};

# ---- route: content-type dispatch ----

subtest 'route: wildcard callback dispatched regardless of content-type' => sub {
    my $dispatched = 0;
    my $handler = {
        method    => 'POST',
        callbacks => {
            '*' => sub { $dispatched++; [200, ['Content-Type' => 'text/plain', 'Content-Length' => 2], ['ok']] },
        },
        pattern   => '/submit',
    };

    my $tpsgi = _make_tpsgi();
    $tpsgi->{routes} = ['/submit', $handler];

    my $body = 'key=val';
    open my $in, '<', \$body;
    my $env = _env(
        REQUEST_METHOD => 'POST',
        PATH_INFO      => '/submit',
        REQUEST_URI    => '/submit',
        CONTENT_TYPE   => 'application/x-www-form-urlencoded',
        CONTENT_LENGTH => length($body),
        'psgi.input'   => $in,
    );
    my $resp = TPSGI::_app($tpsgi, $env);
    is($resp->[0], 200, 'status 200');
    is($dispatched, 1, 'wildcard handler called');
};

subtest 'route: specific content-type dispatched, wrong type returns 400' => sub {
    my $handler = {
        method    => 'POST',
        callbacks => {
            'application/json' => sub { [200, ['Content-Type' => 'text/plain', 'Content-Length' => 2], ['ok']] },
        },
        pattern   => '/json-only',
    };

    my $tpsgi = _make_tpsgi();
    $tpsgi->{routes} = ['/json-only', $handler];

    my $body = 'name=bob';
    open my $in, '<', \$body;
    my $env = _env(
        REQUEST_METHOD => 'POST',
        PATH_INFO      => '/json-only',
        REQUEST_URI    => '/json-only',
        CONTENT_TYPE   => 'application/x-www-form-urlencoded',
        CONTENT_LENGTH => length($body),
        'psgi.input'   => $in,
    );
    my $resp = TPSGI::_app($tpsgi, $env);
    is($resp->[0], 400, 'wrong content-type -> 400');
};

# ---- route: server timing headers ----

subtest 'route: Server-Timing header appended to response' => sub {
    my $handler = {
        method    => 'GET',
        callbacks => { '*' => sub { [200, ['Content-Type' => 'text/plain', 'Content-Length' => 2], ['ok']] } },
        pattern   => '/timing',
    };

    my $tpsgi = _make_tpsgi();
    $tpsgi->{routes} = ['/timing', $handler];

    my $resp = TPSGI::_app($tpsgi, _env(PATH_INFO => '/timing', REQUEST_URI => '/timing'));
    my %headers = @{ $resp->[1] };
    ok(exists $headers{'Server-Timing'}, 'Server-Timing header present');
    like($headers{'Server-Timing'}, qr/dur=/, 'Server-Timing contains duration');
};

# ---- extract_query: GET parameters ----

subtest 'extract_query: GET params parsed from QUERY_STRING' => sub {
    my $handler = {
        method    => 'GET',
        callbacks => { '*' => sub {
            my ($self, $q) = @_;
            [200, ['Content-Type' => 'text/plain', 'Content-Length' => 1], [$q->{name} // '']];
        }},
        pattern   => '/search',
    };

    my $tpsgi = _make_tpsgi();
    $tpsgi->{routes} = ['/search', $handler];

    my $resp = TPSGI::_app($tpsgi, _env(
        PATH_INFO    => '/search',
        REQUEST_URI  => '/search',
        QUERY_STRING => 'name=alice&age=30',
    ));
    is($resp->[0], 200, 'status 200');
    is($resp->[2][0], 'alice', 'name param extracted from QUERY_STRING');
};

subtest 'extract_query: empty QUERY_STRING returns empty hashref (no URL params)' => sub {
    my $tpsgi = _make_tpsgi();
    my $route  = { pattern => '/empty' };
    my $env    = _env(PATH_INFO => '/empty', REQUEST_URI => '/empty', QUERY_STRING => '');

    my $query = TPSGI::extract_query($tpsgi, '/empty', $route, $env);

    # extract_query returns undef or empty hashref when QUERY_STRING is absent
    ok(!defined $query || (ref $query eq 'HASH' && !%$query),
        'extract_query returns empty/undef for empty QUERY_STRING');
};

# ---- extract_query: route captures ----

subtest 'extract_query: captures extracted from URL via regex' => sub {
    my $captured;
    my $handler = {
        method    => 'GET',
        captures  => ['id'],
        callbacks => { '*' => sub {
            my ($self, $q) = @_;
            $captured = $q->{id};
            [200, ['Content-Type' => 'text/plain', 'Content-Length' => 1], ['x']];
        }},
        pattern   => '/item/(\d+)',
    };

    my $tpsgi = _make_tpsgi();
    $tpsgi->{routes} = ['/item/(\d+)', $handler];

    TPSGI::_app($tpsgi, _env(PATH_INFO => '/item/42', REQUEST_URI => '/item/42'));
    is($captured, '42', 'capture group "id" extracted from /item/42');
};

# ---- extract_query: data injection ----

subtest 'extract_query: static data hash injected into query' => sub {
    my $got_mode;
    my $handler = {
        method    => 'GET',
        data      => { mode => 'admin' },
        callbacks => { '*' => sub {
            my ($self, $q) = @_;
            $got_mode = $q->{mode};
            [200, ['Content-Type' => 'text/plain', 'Content-Length' => 1], ['x']];
        }},
        pattern   => '/admin',
    };

    my $tpsgi = _make_tpsgi();
    $tpsgi->{routes} = ['/admin', $handler];

    TPSGI::_app($tpsgi, _env(PATH_INFO => '/admin', REQUEST_URI => '/admin'));
    is($got_mode, 'admin', 'static data hash injected into query');
};

# ---- app: URI too long ----

subtest '_app: URI longer than 2048 chars returns 419' => sub {
    my $tpsgi = _make_tpsgi();
    my $long_path = '/' . ('x' x 2049);
    my $env = _env(PATH_INFO => $long_path, REQUEST_URI => $long_path);
    my $resp = TPSGI::_app($tpsgi, $env);
    is($resp->[0], 419, 'URI > 2048 chars -> 419 toolong');
};

# ---- redirect helpers ----

subtest 'redirect returns 302 with Location header' => sub {
    my $tpsgi = _make_tpsgi();
    my $resp = $tpsgi->redirect('/new-location');
    is($resp->[0], 302, 'redirect -> 302');
    my %headers = @{ $resp->[1] };
    is($headers{Location}, '/new-location', 'Location header set');
};

subtest 'redirect_permanent returns 301' => sub {
    my $tpsgi = _make_tpsgi();
    my $resp = $tpsgi->redirect_permanent('/permanent');
    is($resp->[0], 301, 'redirect_permanent -> 301');
};

subtest 'see_also returns 303' => sub {
    my $tpsgi = _make_tpsgi();
    my $resp = $tpsgi->see_also('/other');
    is($resp->[0], 303, 'see_also -> 303');
};

done_testing;
