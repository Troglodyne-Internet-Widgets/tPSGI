use strict;
use warnings;

use Test::More;
use File::Temp qw(tempdir);
use POSIX qw(strftime);
use Time::HiRes qw(gettimeofday);

# Load stubs for unavailable CPAN deps before loading TPSGI
use lib 't/lib';
use TPSGITestStubs;

use lib 'lib';
require TPSGI;

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

sub make_tpsgi {
    my $tmpdir = tempdir( CLEANUP => 1 );
    return TPSGI->new(
        user      => scalar getpwuid($>),
        http_user => scalar getpwuid($>),
        tpsgi_dir => $tmpdir,
        log_dir   => $tmpdir,
        log_name  => "$tmpdir/test.log",
        routers   => [],
    );
}

# Write a small test file, return its path and mtime
sub make_test_file {
    my ($dir, $content) = @_;
    $content //= "hello world\n";
    my $path = "$dir/test.txt";
    open my $fh, '>', $path or die "Cannot write $path: $!";
    print $fh $content;
    close $fh;
    my $mtime = (stat $path)[9];
    return ($path, $mtime);
}

# ---------------------------------------------------------------------------
# Tests: serve() RFC 7232 §4.1 — 304 MUST NOT include a message body
# ---------------------------------------------------------------------------

my $tpsgi = make_tpsgi();
my $start = [gettimeofday];

subtest 'serve() — 304 when file not modified since last_fetch' => sub {
    my $tmpdir = tempdir( CLEANUP => 1 );
    my ($path, $mtime) = make_test_file($tmpdir);

    # last_fetch is in the future: file appears not-modified
    my $last_fetch = $mtime + 10;
    my $result = $tpsgi->serve("http://test/test.txt", $path, $start, 0, [], $last_fetch, 0);

    is ref $result, 'ARRAY', 'serve returns arrayref';
    is $result->[0], 304, 'status is 304';

    my $body = $result->[2];
    is ref $body, 'ARRAY', 'body slot is arrayref';
    is scalar @$body, 0, '304 response has no body elements (RFC 7232 §4.1)';
};

subtest 'serve() — 200 when file is newer than last_fetch' => sub {
    my $tmpdir = tempdir( CLEANUP => 1 );
    my ($path, $mtime) = make_test_file($tmpdir, "content\n");

    # last_fetch is in the past: file is newer
    my $last_fetch = $mtime - 10;
    my $result = $tpsgi->serve("http://test/test.txt", $path, $start, 0, [], $last_fetch, 0);

    is ref $result, 'ARRAY', 'serve returns arrayref';
    is $result->[0], 200, 'status is 200';

    my $body = $result->[2];
    ok defined $body, '200 response has a body';
    # body should be the filehandle, not empty
    ok $body, 'body is truthy';
};

subtest 'serve() — 304 body is empty even when deflate is requested' => sub {
    my $tmpdir = tempdir( CLEANUP => 1 );
    my ($path, $mtime) = make_test_file($tmpdir, "compressible content " x 100);

    my $last_fetch = $mtime + 100;
    my $result = $tpsgi->serve("http://test/test.txt", $path, $start, 0, [], $last_fetch, 1);

    is $result->[0], 304, 'deflate request: status is 304';
    is scalar @{ $result->[2] }, 0, 'deflate+304: body is empty';
};

subtest 'serve() — 304 does not include Content-Encoding or Content-Length' => sub {
    my $tmpdir = tempdir( CLEANUP => 1 );
    my ($path, $mtime) = make_test_file($tmpdir);

    my $last_fetch = $mtime + 100;
    my $result = $tpsgi->serve("http://test/test.txt", $path, $start, 0, [], $last_fetch, 1);

    my %hdrs = @{ $result->[1] };
    ok !exists $hdrs{'Content-Encoding'}, '304 has no Content-Encoding header';
    ok !exists $hdrs{'Content-Length'},   '304 has no Content-Length header';
};

subtest 'serve() — 304 includes Last-Modified header' => sub {
    my $tmpdir = tempdir( CLEANUP => 1 );
    my ($path, $mtime) = make_test_file($tmpdir);

    my $last_fetch = $mtime + 100;
    my $result = $tpsgi->serve("http://test/test.txt", $path, $start, 0, [], $last_fetch, 0);

    my %hdrs = @{ $result->[1] };
    ok exists $hdrs{'Last-Modified'}, '304 includes Last-Modified (RFC 7232 §4.1)';
};

# ---------------------------------------------------------------------------
# Tests: _app() — ETag 304 log is only emitted when ETag actually matches
# ---------------------------------------------------------------------------

# We test observable behavior: _app() should NOT return 304 when If-None-Match
# doesn't match, and SHOULD return 304 when it does match.

sub make_env {
    my (%extra) = @_;
    return {
        REQUEST_METHOD  => 'GET',
        REQUEST_URI     => '/test',
        PATH_INFO       => '/test',
        QUERY_STRING    => '',
        HTTP_HOST       => 'localhost',
        'psgi.url_scheme' => 'http',
        'psgi.streaming'  => 0,
        'psgi.input'      => do { open my $fh, '<', \'' or die; $fh },
        'psgi.errors'     => \*STDERR,
        REMOTE_ADDR       => '127.0.0.1',
        SERVER_NAME       => 'localhost',
        SERVER_PORT       => 80,
        %extra,
    };
}

subtest '_app() — no 304 when If-None-Match does not match known ETag' => sub {
    my $tpsgi2 = make_tpsgi();

    # Prime the cache: first request stores the ETag (unknown → store it)
    my $prime = make_env( HTTP_IF_NONE_MATCH => '"abc123"', REQUEST_URI => '/etag-test' );
    $tpsgi2->app($prime);    # returns 404, but caches "abc123" for /etag-test

    # Now send a request with a DIFFERENT ETag — should not return 304
    my $env = make_env( HTTP_IF_NONE_MATCH => '"xyz999"', REQUEST_URI => '/etag-test' );
    my $result = $tpsgi2->app($env);
    isnt $result->[0], 304, 'non-matching ETag does not return 304';
};

subtest '_app() — 304 when If-None-Match matches known ETag' => sub {
    my $tpsgi3 = make_tpsgi();

    # Prime the cache
    my $prime = make_env( HTTP_IF_NONE_MATCH => '"abc123"', REQUEST_URI => '/etag-test2' );
    $tpsgi3->app($prime);    # caches "abc123" for /etag-test2

    # Now send a request with the SAME ETag — should return 304
    my $env = make_env( HTTP_IF_NONE_MATCH => '"abc123"', REQUEST_URI => '/etag-test2' );
    my $result = $tpsgi3->app($env);
    is $result->[0], 304, 'matching ETag returns 304';
    is scalar @{ $result->[2] }, 0, '304 ETag response has no body';
};

done_testing;
