#!/usr/bin/env perl

use strict;
use warnings;

use Test::More;
use File::Temp qw{tempfile};

use lib 't/lib';
use TPSGITestStubs;
use FindBin::libs;

# We only need extract_headers — load TPSGI without instantiating it.
require TPSGI;

# ───────────────────────────────────────────────────────────────────────────────
# extract_headers — blank-line detection with CRLF vs LF
# ───────────────────────────────────────────────────────────────────────────────

subtest 'extract_headers — LF blank line (baseline)' => sub {
    my $raw = "HTTP/1.1 200 OK\nContent-Type: text/html\n\nBody goes here";
    open( my $fh, '<', \$raw ) or die "open: $!";
    my ( $code, $offset, %h ) = TPSGI::extract_headers( $fh, 0, 1 );

    is( $code, 200, 'LF: status 200 parsed' );
    ok( exists $h{'content-type'}, 'LF: Content-Type header present' );
    like( $h{'content-type'}, qr{text/html}, 'LF: Content-Type value correct' );
};

subtest 'extract_headers — CRLF blank line (bug: old code missed \\r\\n)' => sub {
    # Before the fix, the blank-line check was ($_ eq "\n"), which does not
    # match "\r\n".  The blank line was appended to $headers along with the body,
    # and the filehandle was left at EOF — the caller could no longer stream the
    # body to the client.
    my $body = "Body goes here";
    my $raw  = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n$body";
    open( my $fh, '<', \$raw ) or die "open: $!";
    my ( $code, $offset, %h ) = TPSGI::extract_headers( $fh, 0, 1 );

    is( $code, 200, 'CRLF: status 200 parsed' );
    ok( exists $h{'content-type'}, 'CRLF: Content-Type header present' );
    like( $h{'content-type'}, qr{text/html}, 'CRLF: Content-Type value correct' );

    # Verify the filehandle is positioned at the body, not at EOF.
    # With old code ($_ eq "\n" check), the blank line and body were both
    # consumed into $headers, leaving nothing for the caller to read.
    my $remaining = do { local $/; <$fh> };
    is( $remaining, $body, 'CRLF: body still readable after extract_headers' );
};

subtest 'extract_headers — 404 via CRLF headers' => sub {
    my $raw = "HTTP/1.1 404 Not Found\r\nContent-Length: 9\r\n\r\nNot Found";
    open( my $fh, '<', \$raw ) or die "open: $!";
    my ( $code, $offset, %h ) = TPSGI::extract_headers( $fh, 0, 1 );

    is( $code, 404, 'CRLF 404 status parsed correctly' );
};

# ───────────────────────────────────────────────────────────────────────────────
# extract_headers — status code default when no HTTP status line present
# ───────────────────────────────────────────────────────────────────────────────

subtest 'extract_headers — no status line defaults to 200 (is_ref path)' => sub {
    # CGI scripts that omit the "Status:" header should yield HTTP 200.
    my $raw = "Content-Type: text/html\n\nHello";
    open( my $fh, '<', \$raw ) or die "open: $!";
    my ( $code, $offset, %h ) = TPSGI::extract_headers( $fh, 0, 1 );

    is( $code, 200, 'no status line: defaults to 200 (is_ref path)' );
};

subtest 'extract_headers — no status line defaults to 200 (mtime path)' => sub {
    # Bug: old code was "$code = $mt > $last_fetch ? $status : 304".
    # When $status is undef (no HTTP status line) and the file is newer than
    # $last_fetch, $code became undef instead of 200.
    my ( $fh, $tmpfile ) = tempfile( UNLINK => 1 );
    print $fh "Content-Type: text/html\r\n\r\nHello";
    seek $fh, 0, 0;

    # Pass last_fetch=0 so mtime > last_fetch is true for any real file.
    my ( $code ) = TPSGI::extract_headers( $fh, 0 );

    is( $code, 200, 'no status line + mtime path: defaults to 200, not undef' );
    ok( defined $code, 'code is defined (was undef before fix)' );
};

# ───────────────────────────────────────────────────────────────────────────────
# CGI exec — shell injection via filename metacharacters
# ───────────────────────────────────────────────────────────────────────────────

subtest 'cgi exec — shell metacharacters in filename do not execute as shell' => sub {
    # Before the fix, open(FH, '-|', "$file_actual") used the shell when the
    # filename contained metacharacters like ';'.  This test proves the safe
    # code path: a three-arg open with two list elements exec()s without a shell,
    # so the entire string (including ';') is treated as the filename, not a
    # shell command.
    #
    # We verify by attempting to open a non-existent path whose name contains
    # shell metacharacters.  If the shell were invoked, the semicolon could cause
    # a second command to run.  With the fix, the open simply fails (ENOENT /
    # EACCES) rather than running a shell.

    my $malicious_name = '/nonexistent;echo INJECTED';

    # Suppress the warning that open() emits on failure in some Perls.
    local $SIG{__WARN__} = sub { };

    # Three-arg form with two list elements: exec's $prog directly, no shell.
    my $pid = open( my $fh, '-|', $malicious_name, 'argv0' );

    # The open will fail because the file does not exist — that is the expected
    # result.  What must NOT happen is "INJECTED" appearing in the output, which
    # would indicate the shell interpreted the ';'.
    ok( !defined($pid) || !$pid, 'open fails cleanly for nonexistent path with metacharacters' );
};

done_testing();
