#!/usr/bin/env perl

use strict;
use warnings;

use File::Temp qw{tempdir tempfile};
use Test::More;
use lib 't/lib';
use TPSGITestStubs;

use lib 'lib';

# Reset Startup package state between tests.
sub reset_startup {
    @TPSGI::Startup::wds      = ();
    @TPSGI::Startup::file_wds = ();
    $TPSGI::Startup::inotify  = undef;
}

# ---- get_config() default for watch -----------------------------------------

subtest 'get_config returns empty watch array by default' => sub {
    local $ENV{HOME} = tempdir(CLEANUP => 1);    # no .tpsgi.ini
    require TPSGI::Startup;
    my %cfg = TPSGI::Startup::get_config();
    ok( exists $cfg{watch},            'watch key present' );
    is( ref $cfg{watch}, 'ARRAY',      'watch is an arrayref' );
    is( scalar @{$cfg{watch}}, 0,      'watch is empty by default' );
};

# ---- get_config() reads watch from .tpsgi.ini --------------------------------

subtest 'get_config reads watch entries from ini' => sub {
    my $home = tempdir(CLEANUP => 1);
    open my $fh, '>', "$home/.tpsgi.ini" or die $!;
    print $fh "[default]\nwatch = /etc/tpsgi.ini\n";
    close $fh;

    local $ENV{HOME} = $home;
    TPSGI::Startup->import() if 0;    # force re-eval of defaults via direct call
    my %cfg = TPSGI::Startup::get_config();
    is( ref $cfg{watch}, 'ARRAY',           'watch is an arrayref' );
    is( scalar @{$cfg{watch}}, 1,           'one watch entry' );
    is( $cfg{watch}[0], '/etc/tpsgi.ini',   'correct watch path' );
};

subtest 'get_config reads multiple watch entries from ini (csv)' => sub {
    my $home = tempdir(CLEANUP => 1);
    open my $fh, '>', "$home/.tpsgi.ini" or die $!;
    # Config::Simple uses CSV for multi-value fields (same as routers)
    print $fh "[default]\nwatch = /etc/tpsgi.ini, /opt/app/config.yaml\n";
    close $fh;

    local $ENV{HOME} = $home;
    my %cfg = TPSGI::Startup::get_config();
    is( scalar @{$cfg{watch}}, 2, 'two watch entries from csv' );
    is( $cfg{watch}[0], '/etc/tpsgi.ini',      'first path correct' );
    is( $cfg{watch}[1], '/opt/app/config.yaml', 'second path correct' );
};

# ---- watch_for_changes() with explicit files vs dirs -------------------------

subtest 'watch_for_changes: explicit non-.pm file goes into file_wds' => sub {
    reset_startup();

    my $tmpdir = tempdir(CLEANUP => 1);

    # Create an explicit non-.pm file
    my (undef, $conf_file) = tempfile(DIR => $tmpdir, SUFFIX => '.ini', UNLINK => 1);

    TPSGI::Startup::watch_for_changes($conf_file);

    ok( scalar @TPSGI::Startup::wds,      'wds populated' );
    ok( scalar @TPSGI::Startup::file_wds, 'file_wds populated for non-.pm file' );
    is( scalar @TPSGI::Startup::file_wds, 1, 'exactly one file_wd' );
};

subtest 'watch_for_changes: explicit .pm file NOT in file_wds' => sub {
    reset_startup();

    my $tmpdir = tempdir(CLEANUP => 1);
    my (undef, $pm_file) = tempfile(DIR => $tmpdir, SUFFIX => '.pm', UNLINK => 1);

    TPSGI::Startup::watch_for_changes($pm_file);

    ok( scalar @TPSGI::Startup::wds,       'wds populated' );
    is( scalar @TPSGI::Startup::file_wds, 0, '.pm file not in file_wds' );
};

subtest 'watch_for_changes: directory does not populate file_wds' => sub {
    reset_startup();

    my $tmpdir = tempdir(CLEANUP => 1);
    # Create a .pm inside so _readdir finds something
    open my $fh, '>', "$tmpdir/Foo.pm" or die $!;
    print $fh "1;\n";
    close $fh;

    TPSGI::Startup::watch_for_changes($tmpdir);

    ok( scalar @TPSGI::Startup::wds,       'wds populated for dir and .pm file' );
    is( scalar @TPSGI::Startup::file_wds, 0, 'no file_wds for directory watches' );
};

subtest 'watch_for_changes: mixed dirs and explicit files' => sub {
    reset_startup();

    my $tmpdir = tempdir(CLEANUP => 1);
    open my $fh, '>', "$tmpdir/Bar.pm" or die $!;
    print $fh "1;\n";
    close $fh;

    my (undef, $conf_file) = tempfile(DIR => $tmpdir, SUFFIX => '.yaml', UNLINK => 1);

    TPSGI::Startup::watch_for_changes($tmpdir, $conf_file);

    ok( scalar @TPSGI::Startup::wds,       'wds populated' );
    is( scalar @TPSGI::Startup::file_wds, 1, 'one file_wd for the explicit yaml' );
};

subtest 'watch_for_changes: idempotent (second call is no-op)' => sub {
    reset_startup();

    my $tmpdir = tempdir(CLEANUP => 1);
    TPSGI::Startup::watch_for_changes($tmpdir);
    my $count = scalar @TPSGI::Startup::wds;

    TPSGI::Startup::watch_for_changes($tmpdir);
    is( scalar @TPSGI::Startup::wds, $count, 'second call does not add more watches' );
};

# ---- restart_if_changes() logic ----------------------------------------------
# We test the change-detection logic by injecting synthetic inotify events.

subtest 'restart_if_changes: triggers on .pm change from dir watch' => sub {
    reset_startup();

    # Build a minimal mock inotify that emits one event with a .pm name
    my $fake_inotify = bless {
        _events => [ { name => 'Foo.pm', wd => 99 } ],
    }, 'Linux::Perl::inotify';

    $TPSGI::Startup::inotify  = $fake_inotify;
    @TPSGI::Startup::wds      = (99);
    @TPSGI::Startup::file_wds = ();

    require TPSGI;

    # We need a minimal TPSGI object. new() checks user/http_user so mock instead.
    my $obj = bless {
        ip       => '127.0.0.1',
        uuid     => 'test-uuid',
        log_name => '/dev/null',
        log_dir  => '/tmp',
        verbose  => 0,
        loggers  => [],
        callbacks => [],
    }, 'TPSGI';

    # Mock the log so we don't need a real file
    {
        no warnings 'redefine';
        local *TPSGI::INFO = sub {};
        local *TPSGI::signal_restart_parent = sub { 1 };

        my $ret = $obj->restart_if_changes();
        is( $ret, 0, 'returns 0 after triggering restart' );
    }
};

subtest 'restart_if_changes: does NOT trigger on non-.pm dir watch event' => sub {
    reset_startup();

    my $fake_inotify = bless {
        _events => [ { name => 'not_pm.txt', wd => 99 } ],
    }, 'Linux::Perl::inotify';

    $TPSGI::Startup::inotify  = $fake_inotify;
    @TPSGI::Startup::wds      = (99);
    @TPSGI::Startup::file_wds = ();

    my $obj = bless {
        ip => '127.0.0.1', uuid => 'test', log_name => '/dev/null',
        log_dir => '/tmp', verbose => 0, loggers => [], callbacks => [],
    }, 'TPSGI';

    no warnings 'redefine';
    local *TPSGI::signal_restart_parent = sub { fail('should not restart') };

    $obj->restart_if_changes();
    ok(1, 'no restart for non-.pm event from dir watch');
};

subtest 'restart_if_changes: triggers on direct file watch (empty name)' => sub {
    reset_startup();

    # Direct file watch event: name is empty, wd matches one in file_wds
    my $fake_inotify = bless {
        _events => [ { name => '', wd => 42 } ],
    }, 'Linux::Perl::inotify';

    $TPSGI::Startup::inotify  = $fake_inotify;
    @TPSGI::Startup::wds      = (42);
    @TPSGI::Startup::file_wds = ("42");    # stringified wd

    my $obj = bless {
        ip => '127.0.0.1', uuid => 'test', log_name => '/dev/null',
        log_dir => '/tmp', verbose => 0, loggers => [], callbacks => [],
    }, 'TPSGI';

    my $restarted = 0;
    {
        no warnings 'redefine';
        local *TPSGI::INFO                  = sub {};
        local *TPSGI::signal_restart_parent = sub { $restarted++ };

        $obj->restart_if_changes();
    }
    is( $restarted, 1, 'restart triggered for direct file watch event' );
};

subtest 'restart_if_changes: empty name but no file_wds does NOT trigger' => sub {
    reset_startup();

    my $fake_inotify = bless {
        _events => [ { name => '', wd => 42 } ],
    }, 'Linux::Perl::inotify';

    $TPSGI::Startup::inotify  = $fake_inotify;
    @TPSGI::Startup::wds      = (42);
    @TPSGI::Startup::file_wds = ();    # no explicit file watches

    my $obj = bless {
        ip => '127.0.0.1', uuid => 'test', log_name => '/dev/null',
        log_dir => '/tmp', verbose => 0, loggers => [], callbacks => [],
    }, 'TPSGI';

    no warnings 'redefine';
    local *TPSGI::signal_restart_parent = sub { fail('should not restart') };

    $obj->restart_if_changes();
    ok(1, 'no restart when empty name but no explicit file watches');
};

done_testing();
