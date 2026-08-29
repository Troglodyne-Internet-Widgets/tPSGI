#!/usr/bin/env perl

# Tests for suffix byte-range support in _range().
# RFC 7233 §2.1: bytes=-N means "the last N bytes of the representation".
# parse_ranges() splits "-500" into ["", "500"]; _range() must convert that
# to [size-500, size-1] before serving — previously it fell through to 0-499.

use strict;
use warnings;

use Test::More;
use File::Temp qw{tempfile};
use List::Util qw{sum};

use lib 't/lib';
use TPSGITestStubs;
use lib 'lib';

use TPSGI;

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

sub make_tpsgi {
    return bless {
        verbose  => 0,
        log_name => '/dev/null',
        log_dir  => '/tmp',
        ip       => '127.0.0.1',
    }, 'TPSGI';
}

{
    no strict 'refs';
    no warnings 'redefine', 'once';
    *TPSGI::INFO  = sub { };
    *TPSGI::WARN  = sub { };
    *TPSGI::DEBUG = sub { };
}

sub make_tempfile {
    my ($content) = @_;
    my ( $fh, $path ) = tempfile( UNLINK => 1 );
    binmode $fh;
    print $fh $content;
    seek $fh, 0, 0;
    return ( $path, $fh, length($content) );
}

sub run_range {
    my ( $tpsgi, $fullpath, $fh, $ranges, $sz, %headers ) = @_;
    my $result = TPSGI::_range( $tpsgi, $fullpath, $fh, $ranges, $sz, %headers );
    return $result unless ref $result eq 'CODE';

    my ( $code, @resp_headers, @written );
    my $mock_responder = sub {
        ( $code, my $hdr_ref ) = @{ $_[0] };
        @resp_headers = @$hdr_ref;
        return bless {}, 'MockWriter10';
    };
    {
        no strict 'refs';
        no warnings 'redefine', 'once';
        *MockWriter10::write = sub { push @written, $_[1] };
        *MockWriter10::close = sub { };
    }
    $result->($mock_responder);
    return { code => $code, headers => \@resp_headers, body => join( '', @written ) };
}

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

my $t = make_tpsgi();

my %base_headers = ( 'Content-type' => 'text/plain' );

# Content: bytes 0-9 = "0123456789"
my $content = join( '', 0..9 );    # "0123456789", 10 bytes

subtest 'suffix range bytes=-5 returns last 5 bytes' => sub {
    my ( $path, $fh, $sz ) = make_tempfile($content);
    is $sz, 10, 'file is 10 bytes';

    # Suffix range: bytes=-5 -> ["", "5"] from parse_ranges
    my $ranges = [ [ '', 5 ] ];
    my $r = run_range( $t, '/test', $fh, $ranges, $sz, %base_headers );

    is ref $r, 'HASH', 'got streaming result';
    is $r->{code}, 206, '206 Partial Content';
    is $r->{body}, '56789', 'last 5 bytes served (bytes 5-9)';

    my %hdrs = @{ $r->{headers} };
    is $hdrs{'Content-Range'}, 'bytes 5-9/10', 'Content-Range reflects suffix expansion';
    is $hdrs{'Content-Length'}, 5, 'Content-Length = 5';
};

subtest 'suffix range bytes=-10 (= full file) returns all bytes' => sub {
    my ( $path, $fh, $sz ) = make_tempfile($content);
    my $ranges = [ [ '', 10 ] ];
    my $r = run_range( $t, '/test', $fh, $ranges, $sz, %base_headers );

    is $r->{code}, 206, '206';
    is $r->{body}, $content, 'all 10 bytes served';
};

subtest 'suffix range larger than file size returns full file' => sub {
    my ( $path, $fh, $sz ) = make_tempfile($content);
    my $ranges = [ [ '', 999 ] ];
    my $r = run_range( $t, '/test', $fh, $ranges, $sz, %base_headers );

    is $r->{code}, 206, '206';
    is $r->{body}, $content, 'all bytes served when suffix > file size';
    my %hdrs = @{ $r->{headers} };
    is $hdrs{'Content-Range'}, 'bytes 0-9/10', 'range clamped to 0-9';
};

subtest 'suffix range bytes=-1 returns last byte' => sub {
    my ( $path, $fh, $sz ) = make_tempfile($content);
    my $ranges = [ [ '', 1 ] ];
    my $r = run_range( $t, '/test', $fh, $ranges, $sz, %base_headers );

    is $r->{body}, '9', 'last byte is "9"';
    my %hdrs = @{ $r->{headers} };
    is $hdrs{'Content-Range'}, 'bytes 9-9/10', 'Content-Range correct';
};

subtest 'parse_ranges produces suffix range entry for bytes=-N' => sub {
    my @ranges = TPSGI::parse_ranges({ HTTP_RANGE => 'bytes=-5' });
    is scalar @ranges, 1, 'one range';
    is $ranges[0][0], '', 'first element is empty string (suffix sentinel)';
    is $ranges[0][1], 5,  'suffix length is 5';
};

subtest 'ordinary range bytes=0-4 still works after suffix range' => sub {
    my ( $path, $fh, $sz ) = make_tempfile($content);
    my $ranges = [ [ 0, 4 ] ];
    my $r = run_range( $t, '/test', $fh, $ranges, $sz, %base_headers );

    is $r->{body}, '01234', 'bytes 0-4 served correctly';
    my %hdrs = @{ $r->{headers} };
    is $hdrs{'Content-Range'}, 'bytes 0-4/10', 'Content-Range correct';
};

done_testing;
