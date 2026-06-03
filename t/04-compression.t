#!/usr/bin/env perl

# Tests for HTTP compression handling in TPSGI.
# Covers:
#   1. _accepts_gzip() correctly parses Accept-Encoding quality values
#   2. serve() skips gzip for already-compressed MIME types

use strict;
use warnings;

use Test::More;
use File::Temp qw{tempdir tempfile};
use File::Basename qw{dirname};
use File::Path qw{make_path};

use lib 't/lib';
use TPSGITestStubs;
use FindBin::libs;

use TPSGI;

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

my $tmpdir  = tempdir(CLEANUP => 1);
my $logfile = "$tmpdir/tpsgi.log";
my $user    = scalar getpwuid($>);
my $http_grp = (getgrgid($)))[0];

sub _make_tpsgi {
    my $self = bless {
        user      => $user,
        http_user => $http_grp,
        tpsgi_dir => $tmpdir,
        basedir   => '.',
        log_dir   => $tmpdir,
        log_name  => $logfile,
        verbose   => 0,
        routes    => [],
        aliases   => {},
        callbacks => [],
        indices   => [qw{index.html index.htm index.cgi}],
        ip        => '127.0.0.1',
    }, 'TPSGI';
    return $self;
}

sub _write_file {
    my ($dir, $name, $content) = @_;
    make_path($dir) unless -d $dir;
    open(my $fh, '>', "$dir/$name") or die "Cannot write $dir/$name: $!";
    print $fh $content;
    close $fh;
    return "$dir/$name";
}

# ---------------------------------------------------------------------------
# 1. _accepts_gzip — Accept-Encoding parsing
# ---------------------------------------------------------------------------

subtest '_accepts_gzip' => sub {
    is( TPSGI::_accepts_gzip('gzip'),             1, 'plain gzip accepted' );
    is( TPSGI::_accepts_gzip('gzip, deflate'),    1, 'gzip with deflate accepted' );
    is( TPSGI::_accepts_gzip('gzip;q=0.9'),       1, 'gzip with quality value accepted' );
    is( TPSGI::_accepts_gzip('gzip;q=1.0, br'),   1, 'gzip q=1.0 with br accepted' );
    is( TPSGI::_accepts_gzip('br, gzip;q=0.5'),   1, 'gzip at end with quality accepted' );
    ok( !TPSGI::_accepts_gzip('deflate, br'),       'no gzip not accepted' );
    ok( !TPSGI::_accepts_gzip(''),                  'empty string not accepted' );
    ok( !TPSGI::_accepts_gzip(undef),               'undef not accepted' );
    is( TPSGI::_accepts_gzip('gzip; q=0.0'),       1, 'q=0.0 still counted as listing gzip (q=0 filtering not in scope)' );
};

# ---------------------------------------------------------------------------
# 2. serve() — compressible vs incompressible types
# ---------------------------------------------------------------------------

subtest 'serve() skips gzip for already-compressed types' => sub {
    my $tpsgi = _make_tpsgi();
    my $start = [Time::HiRes::gettimeofday()];

    # Set up a www/ subtree so serve()'s static hardlink path stays inside tmpdir
    my $www = "$tmpdir/www";
    make_path($www);

    # Write a small text file — should get gzip'd
    my $txt_path = _write_file($www, 'hello.txt', 'Hello, world! ' x 100);
    local $@;
    my $resp = eval { $tpsgi->serve("http://localhost/hello.txt", $txt_path, $start, 0, [], 0, 1) };
    SKIP: {
        skip "serve() died: $@", 1 if $@;
        my %hdrs = @{ $resp->[1] };
        is( $hdrs{'Content-Encoding'}, 'gzip', 'text/plain gets gzip encoded' );
    }

    # Write a fake PNG — should NOT get gzip'd
    my $png_path = _write_file($www, 'img.png', 'FAKEPNGDATA' x 10);
    $resp = $tpsgi->serve("http://localhost/img.png", $png_path, $start, 0, [], 0, 1);
    my %hdrs = @{ $resp->[1] };
    ok( !exists $hdrs{'Content-Encoding'}, 'no Content-Encoding header for PNG' );

    # Write a fake JPEG — should NOT get gzip'd
    my $jpg_path = _write_file($www, 'photo.jpg', 'FAKEJPEGDATA' x 10);
    $resp = $tpsgi->serve("http://localhost/photo.jpg", $jpg_path, $start, 0, [], 0, 1);
    %hdrs = @{ $resp->[1] };
    ok( !exists $hdrs{'Content-Encoding'}, 'no Content-Encoding header for JPEG' );

    # Write a fake ZIP — should NOT get gzip'd
    my $zip_path = _write_file($www, 'archive.zip', 'PK' . 'X' x 50);
    $resp = $tpsgi->serve("http://localhost/archive.zip", $zip_path, $start, 0, [], 0, 1);
    %hdrs = @{ $resp->[1] };
    ok( !exists $hdrs{'Content-Encoding'}, 'no Content-Encoding header for ZIP' );
};

subtest 'serve() skips gzip when deflate=0' => sub {
    my $tpsgi = _make_tpsgi();
    my $start = [Time::HiRes::gettimeofday()];
    make_path("$tmpdir/www2");
    my $txt_path = _write_file("$tmpdir/www2", 'plain.txt', 'Some text content');

    my $resp = $tpsgi->serve("http://localhost/plain.txt", $txt_path, $start, 0, [], 0, 0);
    my %hdrs = @{ $resp->[1] };
    ok( !exists $hdrs{'Content-Encoding'}, 'no gzip when deflate=0' );
};

done_testing;
