#!/usr/bin/env perl

# Tests for parse_ranges() including the stale-variable bug where a previous
# range request's value leaked into a subsequent request that had no range headers.

use strict;
use warnings;

use Test::More;
use File::Temp qw{tempdir};

use lib 't/lib';
use TPSGITestStubs;
use FindBin::libs;

use TPSGI;

# ---- Basic functionality (already stable) ----

subtest 'no range header returns empty list' => sub {
    my @ranges = TPSGI::parse_ranges({});
    is(scalar @ranges, 0, 'empty list for bare request');
};

subtest 'single byte range parsed' => sub {
    my @ranges = TPSGI::parse_ranges({ HTTP_RANGE => 'bytes=0-1023' });
    is(scalar @ranges, 1,   'one range');
    is($ranges[0][0], 0,    'start = 0');
    is($ranges[0][1], 1023, 'end = 1023');
};

subtest 'multiple ranges parsed' => sub {
    my @ranges = TPSGI::parse_ranges({ HTTP_RANGE => 'bytes=0-499,1000-1499' });
    is(scalar @ranges, 2,    'two ranges');
    is($ranges[0][0], 0,     'first start = 0');
    is($ranges[0][1], 499,   'first end = 499');
    is($ranges[1][0], 1000,  'second start = 1000');
    is($ranges[1][1], 1499,  'second end = 1499');
};

subtest 'open-ended range: end is undef' => sub {
    my @ranges = TPSGI::parse_ranges({ HTTP_RANGE => 'bytes=500-' });
    is(scalar @ranges, 1, 'one range');
    is($ranges[0][0], 500, 'start = 500');
    ok(!defined $ranges[0][1], 'end is undef for open-ended range');
};

subtest 'IF_RANGE without RANGE uses full-file default range' => sub {
    my @ranges = TPSGI::parse_ranges({ HTTP_IF_RANGE => '"some-etag"' });
    is(scalar @ranges, 1, 'default range generated');
    is($ranges[0][0], 0, 'default start = 0');
    ok(!defined $ranges[0][1], 'default end undef');
};

# ---- Stale variable bug regression test ----
# The old code used `my $range = val if cond` — Perl UB that causes $range to
# retain its previous value when the condition is false on a subsequent call.
# After the fix, a ranged call followed by a non-ranged call must return empty.

subtest 'non-ranged call after ranged call returns empty list (stale-variable fix)' => sub {
    # First call: with a range — establishes a value in the old buggy code
    my @first = TPSGI::parse_ranges({ HTTP_RANGE => 'bytes=0-255' });
    is(scalar @first, 1, 'first call: range returned');

    # Second call: no range headers at all — must return empty, not stale range
    my @second = TPSGI::parse_ranges({});
    is(scalar @second, 0, 'second call: no range headers -> empty list (not stale)');
};

subtest 'multiple non-ranged calls in sequence all return empty' => sub {
    # Seed a range first
    TPSGI::parse_ranges({ HTTP_RANGE => 'bytes=100-200' });

    for my $i (1..3) {
        my @ranges = TPSGI::parse_ranges({});
        is(scalar @ranges, 0, "call $i: no ranges returned without header");
    }
};

subtest 'IF_RANGE followed by no-range call returns empty' => sub {
    TPSGI::parse_ranges({ HTTP_IF_RANGE => '"etag-abc"' });
    my @ranges = TPSGI::parse_ranges({});
    is(scalar @ranges, 0, 'no range headers after IF_RANGE -> empty list');
};

done_testing;
