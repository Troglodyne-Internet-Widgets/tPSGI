#!/usr/bin/env perl

# Tests for static() RFC 7232 §4.1 compliance.
# A 304 Not Modified response MUST NOT include a message body.
# Previously static() called extract_headers() which could return code=304,
# but static() ignored the code and streamed/returned the file body anyway.

use strict;
use warnings;

use Test::More;
use File::Temp qw{tempdir};
use Time::HiRes qw{gettimeofday};
use POSIX qw{strftime};
use Cwd qw{getcwd};

use lib 't/lib';
use TPSGITestStubs;
use lib 'lib';

use TPSGI;

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

my $tmpdir = tempdir( CLEANUP => 1 );

sub make_tpsgi {
    return bless {
        verbose   => 0,
        log_name  => '/dev/null',
        log_dir   => '/tmp',
        ip        => '127.0.0.1',
        tpsgi_dir => $tmpdir,
        callbacks => [],
    }, 'TPSGI';
}

{
    no strict 'refs';
    no warnings 'redefine', 'once';
    *TPSGI::INFO  = sub { };
    *TPSGI::WARN  = sub { };
    *TPSGI::DEBUG = sub { };
}

sub _start { return [gettimeofday] }

# static() opens "statics/$path" relative to CWD.
# We chdir into a temp dir that has a statics/ subdirectory for the tests.
my $statics_dir = "$tmpdir/statics";
mkdir $statics_dir or die "mkdir: $!";

# Write a static file with embedded HTTP headers (the format static() expects).
# extract_headers() reads until a blank line, then the body follows.
sub write_static {
    my ( $name, $body, %extra_headers ) = @_;
    my $path = "$statics_dir/$name";
    open my $fh, '>', $path or die "open $path: $!";
    # Static files must have an HTTP status line so extract_headers can parse $status.
    print $fh "HTTP/1.1 200 OK\r\n";
    print $fh "Content-Type: text/plain\r\n";
    print $fh "Content-Length: " . length($body) . "\r\n";
    for my $k ( keys %extra_headers ) {
        print $fh "$k: $extra_headers{$k}\r\n";
    }
    print $fh "\r\n";
    print $fh $body;
    close $fh;
    return $path;
}

# Save CWD and switch to the temp dir so that "statics/$path" resolves.
my $orig_cwd = getcwd();
chdir $tmpdir or die "chdir: $!";

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

my $t = make_tpsgi();

subtest 'static() returns 200 with body for unmodified file (last_fetch=0)' => sub {
    write_static( 'hello.txt', 'Hello static world' );

    my $resp = $t->static( '/hello.txt', 'hello.txt', _start(), 0, 0 );
    is ref $resp, 'ARRAY', 'got arrayref';
    is $resp->[0], 200, 'status 200';
    ok defined $resp->[2], 'body slot defined';
};

subtest 'static() returns 304 with no body when file not modified (RFC 7232 §4.1)' => sub {
    my $file_path = write_static( 'cached.txt', 'Cached content' );
    my $mtime = ( stat $file_path )[9];

    # last_fetch is after mtime — file appears not-modified
    my $last_fetch = $mtime + 3600;

    my $resp = $t->static( '/cached.txt', 'cached.txt', _start(), 0, $last_fetch );
    is ref $resp, 'ARRAY', 'got arrayref';
    is $resp->[0], 304, 'status is 304';

    my $body = $resp->[2];
    is ref $body, 'ARRAY', 'body slot is arrayref (not filehandle)';
    is scalar @$body, 0, '304 body is empty (RFC 7232 §4.1 — no message body)';
};

subtest 'static() streaming 304 returns CODE ref that sends no body' => sub {
    my $file_path = write_static( 'stream-cached.txt', 'Streamable content' );
    my $mtime = ( stat $file_path )[9];
    my $last_fetch = $mtime + 3600;

    my $resp = $t->static( '/stream-cached.txt', 'stream-cached.txt', _start(), 1, $last_fetch );

    # Should be an arrayref [304, ...] — not a CODE ref that would stream body
    is ref $resp, 'ARRAY', '304 is not a streaming CODE ref';
    is $resp->[0], 304, 'status is 304';
    is scalar @{ $resp->[2] }, 0, 'no body chunks';
};

subtest 'static() returns 403 for missing file' => sub {
    # Use $cur_query instead of $self->{current_query} — this test verifies the
    # error path doesn't crash (PR #10 fixes the crash; this just checks we get 403).
    my $resp = $t->static( '/no-such.txt', 'no-such.txt', _start(), 0, 0 );
    is $resp->[0], 403, '403 for missing static file';
};

# Restore CWD
chdir $orig_cwd;

done_testing;
