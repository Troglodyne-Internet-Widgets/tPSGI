#!/usr/bin/env perl

# Tests for pure-function utilities in TPSGI that don't require an object:
#   parse_ranges, appears_executable, extract_headers

use strict;
use warnings;

use Test::More;
use File::Temp qw{tempfile};

use lib 't/lib';
use TPSGITestStubs;
use FindBin::libs;

use TPSGI;

# ---- parse_ranges ----

subtest 'parse_ranges: no range header returns empty list' => sub {
    my @ranges = TPSGI::parse_ranges({});
    is(scalar @ranges, 0, 'empty list for bare request');
};

subtest 'parse_ranges: single byte range' => sub {
    my @ranges = TPSGI::parse_ranges({ HTTP_RANGE => 'bytes=0-1023' });
    is(scalar @ranges, 1,    'one range parsed');
    is($ranges[0][0], 0,     'start = 0');
    is($ranges[0][1], 1023,  'end = 1023');
};

subtest 'parse_ranges: multiple ranges' => sub {
    my @ranges = TPSGI::parse_ranges({ HTTP_RANGE => 'bytes=0-499,1000-1499' });
    is(scalar @ranges, 2,    'two ranges');
    is($ranges[0][0], 0,     'first start');
    is($ranges[0][1], 499,   'first end');
    is($ranges[1][0], 1000,  'second start');
    is($ranges[1][1], 1499,  'second end');
};

subtest 'parse_ranges: open-ended range (no end specified)' => sub {
    my @ranges = TPSGI::parse_ranges({ HTTP_RANGE => 'bytes=500-' });
    is(scalar @ranges, 1,   'one range');
    is($ranges[0][0], 500,  'start = 500');
    ok(!defined $ranges[0][1], 'end is undef for open-ended range');
};

subtest 'parse_ranges: IF_RANGE without RANGE uses full-file default' => sub {
    my @ranges = TPSGI::parse_ranges({ HTTP_IF_RANGE => '"some-etag"' });
    is(scalar @ranges, 1,   'default range generated');
    is($ranges[0][0], 0,    'default start = 0');
    ok(!defined $ranges[0][1], 'default end undef');
};

# ---- appears_executable ----

subtest 'appears_executable: undef returns false' => sub {
    ok(!TPSGI::appears_executable(undef), 'undef -> not executable');
};

subtest 'appears_executable: nonexistent path returns false' => sub {
    ok(!TPSGI::appears_executable('/this/path/does/not/exist.sh'), 'missing file -> not executable');
};

subtest 'appears_executable: non-executable file returns false' => sub {
    my ($fh, $path) = tempfile(UNLINK => 1, SUFFIX => '.txt');
    close $fh;
    chmod 0644, $path;
    ok(!TPSGI::appears_executable($path), 'chmod 644 file -> not executable');
};

subtest 'appears_executable: executable file with no extension returns true' => sub {
    my ($fh, $path) = tempfile(UNLINK => 1);
    close $fh;
    chmod 0755, $path;
    ok(TPSGI::appears_executable($path), 'executable, no extension -> true');
};

for my $ext (qw{cgi sh pl py php exe}) {
    subtest "appears_executable: executable .$ext file returns true" => sub {
        my ($fh, $path) = tempfile(UNLINK => 1, SUFFIX => ".$ext");
        close $fh;
        chmod 0755, $path;
        ok(TPSGI::appears_executable($path), ".$ext executable -> true");
    };
}

subtest 'appears_executable: executable .html file returns false' => sub {
    my ($fh, $path) = tempfile(UNLINK => 1, SUFFIX => '.html');
    close $fh;
    chmod 0755, $path;
    ok(!TPSGI::appears_executable($path), '.html file is not treated as executable');
};

subtest 'appears_executable: executable .css file returns false' => sub {
    my ($fh, $path) = tempfile(UNLINK => 1, SUFFIX => '.css');
    close $fh;
    chmod 0755, $path;
    ok(!TPSGI::appears_executable($path), '.css file is not treated as executable');
};

done_testing;
