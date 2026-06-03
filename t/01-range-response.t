#!/usr/bin/env perl
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/lib";
use TPSGITestStubs;

use File::Temp qw{ tempfile };
use Scalar::Util qw{ looks_like_number };
use Test::More;

# We test _range() indirectly through serve() by calling the internal function
# directly to avoid needing a full PSGI env.

# Load TPSGI after stubs so missing deps are already mocked.
require TPSGI;

# ── helpers ────────────────────────────────────────────────────────────────

# Minimal TPSGI object with log() stubbed out.
sub make_tpsgi {
    my %opts = @_;
    my $t = bless {
        verbose  => 0,
        log_name => '/dev/null',
        log_dir  => '/tmp',
        ip       => '127.0.0.1',
        %opts,
    }, 'TPSGI';
    no strict 'refs';
    no warnings 'redefine', 'once';
    *TPSGI::INFO  = sub { };
    *TPSGI::WARN  = sub { };
    *TPSGI::DEBUG = sub { };
    return $t;
}

# Create a temp file with $content and return ( fullpath, filehandle, size ).
sub make_tempfile {
    my $content = shift;
    my ( $fh, $path ) = tempfile( UNLINK => 1 );
    print $fh $content;
    seek $fh, 0, 0;
    return ( $path, $fh, length($content) );
}

# Capture what _range() returns by invoking it and collecting writer calls.
sub run_range {
    my ( $tpsgi, $fullpath, $fh, $ranges, $sz, %headers ) = @_;

    my $result = TPSGI::_range( $tpsgi, $fullpath, $fh, $ranges, $sz, %headers );

    return $result unless ref $result eq 'CODE';

    my @written;
    my $code;
    my @resp_headers;

    my $mock_responder = sub {
        ( $code, my $hdr_ref ) = @{ $_[0] };
        @resp_headers = @$hdr_ref;
        return bless {}, 'MockWriter';
    };

    no strict 'refs';
    no warnings 'redefine', 'once';
    *MockWriter::write = sub { push @written, $_[1] };
    *MockWriter::close = sub { };

    $result->($mock_responder);
    return { code => $code, headers => \@resp_headers, body => join( '', @written ) };
}

# ── tests ──────────────────────────────────────────────────────────────────

my $t = make_tpsgi();

# 1. 416 for out-of-bounds range (start > size)
{
    my ( $path, $fh, $sz ) = make_tempfile('hello');

    my $resp = TPSGI::_range( $t, '/test', $fh, [ [10, 20] ], $sz,
        'Content-type' => 'text/plain' );

    is( ref $resp, 'ARRAY', '416: result is arrayref' );
    is( $resp->[0], 416,    '416: correct status for out-of-bounds start' );
}

# 2. 416 for inverted range (start > end)
{
    my ( $path, $fh, $sz ) = make_tempfile('hello');

    my $resp = TPSGI::_range( $t, '/test', $fh, [ [3, 1] ], $sz,
        'Content-type' => 'text/plain' );

    is( $resp->[0], 416, '416: inverted range (start > end)' );
}

# 3. Valid single range — correct Content-Length
{
    my ( $path, $fh, $sz ) = make_tempfile('hello world');    # 11 bytes

    my $result = run_range( $t, '/test', $fh, [ [0, 4] ], $sz,
        'Content-type' => 'text/plain' );

    is( $result->{code}, 206, 'single range: 206 status' );

    my %h = @{ $result->{headers} };
    is( $h{'Content-Length'}, 5, 'single range: Content-Length = 5 for bytes 0-4' );
    is( $result->{body},      'hello', 'single range: body is first 5 bytes' );
}

# 4. Overlong range end clamped — Content-Length must not exceed file size
{
    my ( $path, $fh, $sz ) = make_tempfile('hello');    # 5 bytes

    my $result = run_range( $t, '/test', $fh, [ [0, 9999] ], $sz,
        'Content-type' => 'text/plain' );

    is( $result->{code}, 206, 'overlong end: 206 status' );

    my %h = @{ $result->{headers} };
    is( $h{'Content-Length'}, 5, 'overlong end: Content-Length clamped to file size' );
    is( length( $result->{body} ), 5, 'overlong end: body length equals file size' );
    is( $result->{body}, 'hello', 'overlong end: body is full file content' );
}

# 5. Overlong range Content-Range header reflects clamped values
{
    my ( $path, $fh, $sz ) = make_tempfile('hello');    # 5 bytes

    my $result = run_range( $t, '/test', $fh, [ [0, 9999] ], $sz,
        'Content-type' => 'text/plain' );

    my %h = @{ $result->{headers} };
    is( $h{'Content-Range'}, 'bytes 0-4/5', 'overlong end: Content-Range reflects clamped end' );
}

# 6. Suffix range (open-ended) defaults to last byte
{
    my ( $path, $fh, $sz ) = make_tempfile('hello world');    # 11 bytes

    # bytes=6- (last 5 bytes)
    my $result = run_range( $t, '/test', $fh, [ [6, undef] ], $sz,
        'Content-type' => 'text/plain' );

    is( $result->{code}, 206, 'suffix range: 206 status' );

    my %h = @{ $result->{headers} };
    is( $h{'Content-Length'}, 5, 'suffix range: Content-Length = 5' );
    is( $result->{body},      'world', 'suffix range: body is tail of file' );
}

# 7. Valid 416 does not return 206
{
    my ( $path, $fh, $sz ) = make_tempfile('hi');    # 2 bytes

    my $resp = TPSGI::_range( $t, '/test', $fh, [ [5, 10] ], $sz,
        'Content-type' => 'text/plain' );

    isnt( $resp->[0], 206, '416 path never returns 206' );
    is(   $resp->[0], 416, '416 path returns 416' );
}

# 8. Multipart — Content-Length includes correct terminator (no extra backslash)
{
    my ( $path, $fh, $sz ) = make_tempfile('0123456789');    # 10 bytes

    my $result = run_range( $t, '/test', $fh, [ [0, 1], [4, 5] ], $sz,
        'Content-type' => 'text/plain' );

    is( $result->{code}, 206, 'multipart: 206 status' );

    my %h = @{ $result->{headers} };
    my $declared = $h{'Content-Length'};
    my $actual   = length( $result->{body} );

    ok( looks_like_number($declared), 'multipart: Content-Length is numeric' );
    is( $declared, $actual, "multipart: Content-Length ($declared) matches actual body length ($actual)" );
}

done_testing();
