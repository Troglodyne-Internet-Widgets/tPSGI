#!/usr/bin/env perl

# Tests for two bugs:
#
# 1. static() used $self->{current_query} (nonexistent key) instead of the
#    package-global $cur_query when reporting a forbidden response.
#    Before the fix this caused "Can't use undefined value as HASH reference".
#
# 2. $generic_handler was unconditionally set to "Package::generic_route" even
#    when the loaded router module does NOT define that sub.  Any subsequent
#    error response (404, 400, 500 …) would then die with
#    "Undefined subroutine &Package::generic_route called".

use strict;
use warnings;

use Test::More;
use File::Temp qw{tempdir};
use Time::HiRes qw{gettimeofday};
use File::Path qw{make_path};
use Cwd qw{getcwd};

use lib 't/lib';
use TPSGITestStubs;
use FindBin::libs;

use TPSGI;

my $tmpdir   = tempdir(CLEANUP => 1);
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

# ------------------------------------------------------------------ #
# Bug 1: static() wrong cur_query reference                           #
# ------------------------------------------------------------------ #

subtest 'static() returns 403 without crashing when file is unreadable' => sub {
    # Before fix: $self->{current_query} was always undef, so forbidden()
    # would die "Can't use undefined value as HASH reference".
    # After fix: package-global $cur_query is used which is always a hashref.

    my $tpsgi = _make_tpsgi();
    my $start = [gettimeofday];

    # Pass a path that does not exist — open() fails, triggering the error
    # path that previously crashed.  Suppress non-root chown/make_path noise.
    open(my $old_err, '>&', \*STDERR);
    open(STDERR, '>', '/dev/null');
    my $resp = eval { $tpsgi->static('/no/such/path', 'no/such/file.txt', $start, 0, 0) };
    my $err  = $@;
    open(STDERR, '>&', $old_err);

    is($err,           '',     'static() with missing file does not die');
    ok(ref $resp eq 'ARRAY',   'returns ARRAY ref');
    is($resp->[0],     403,    'returns 403 Forbidden');
};


# ------------------------------------------------------------------ #
# Bug 2: $generic_handler set unconditionally                         #
# ------------------------------------------------------------------ #

# To test via the real new() codepath, write actual .pm files to disk.
# Router WITHOUT generic_route — this exposed the bug.

my $router_dir = "$tmpdir/routers";
make_path($router_dir);

# Router that does NOT define generic_route
open(my $rf1, '>', "$router_dir/RouterNoGeneric.pm") or die "can't write router: $!";
print $rf1 <<'END_PM';
package RouterNoGeneric;
our @routes  = ('/test', { method => 'GET', callbacks => { '*' => sub { [200, [], ['ok']] } }, pattern => '/test' });
our %aliases = ();
1;
END_PM
close $rf1;

# Router that DOES define generic_route
our $generic_called = 0;
open(my $rf2, '>', "$router_dir/RouterHasGeneric.pm") or die "can't write router: $!";
print $rf2 <<'END_PM';
package RouterHasGeneric;
our @routes  = ('/test2', { method => 'GET', callbacks => { '*' => sub { [200, [], ['ok']] } }, pattern => '/test2' });
our %aliases = ();
sub generic_route {
    $main::generic_called = 1;
    return [ $_[1], ['Content-Type' => 'text/html'], ["Custom $_[1]"] ];
}
1;
END_PM
close $rf2;

sub _new_tpsgi_with_router {
    my ($router_file) = @_;

    # Temporarily stash / restore INC state to avoid cross-test pollution
    return TPSGI->new(
        user       => $user,
        http_user  => $http_grp,
        tpsgi_dir  => $tmpdir,
        log_dir    => $tmpdir,
        log_name   => "$tmpdir/tpsgi.log",
        verbose    => 0,
        autoreload => 0,
        indices    => [qw{index.html}],
        routers    => [$router_file],
        loggers    => [],
    );
}

subtest 'notfound returns 404 and does not die when router lacks generic_route' => sub {
    # Before fix: new() set $generic_handler = "RouterNoGeneric::generic_route"
    # even though that sub doesn't exist.  The next notfound() call would die
    # "Undefined subroutine &RouterNoGeneric::generic_route called".
    # After fix: $generic_handler stays undef; _generic() falls back to plain text.

    my $tpsgi;
    my $err = '';
    {
        # Silence the router-loading debug output
        open(my $old_err, '>&', \*STDERR);
        open(STDERR, '>', '/dev/null');
        eval { $tpsgi = _new_tpsgi_with_router("routers/RouterNoGeneric.pm") };
        $err = $@;
        open(STDERR, '>&', $old_err);
    }

    is($err, '', "new() with router lacking generic_route does not die: $err");

    my $query = { method => 'GET', fullpath => '/gone', tpsgi => $tpsgi, ip => '127.0.0.1', ua => '', referer => '' };
    my $resp = eval { $tpsgi->notfound($query) };
    is($@, '',  'notfound() does not die');
    ok(defined $resp && ref $resp eq 'ARRAY', 'returns ARRAY ref');
    is($resp->[0], 404, 'returns 404');
};

subtest 'notfound invokes generic_route when router defines it' => sub {
    $main::generic_called = 0;

    my $tpsgi;
    {
        open(my $old_err, '>&', \*STDERR);
        open(STDERR, '>', '/dev/null');
        eval { $tpsgi = _new_tpsgi_with_router("routers/RouterHasGeneric.pm") };
        open(STDERR, '>&', $old_err);
    }

    my $query = { method => 'GET', fullpath => '/gone', tpsgi => $tpsgi, ip => '127.0.0.1', ua => '', referer => '' };
    my $resp = eval { $tpsgi->notfound($query) };
    is($@, '', 'no exception');
    is($main::generic_called, 1, 'generic_route was invoked');
    is($resp->[0], 404, '404 status from custom handler');
};

done_testing();
