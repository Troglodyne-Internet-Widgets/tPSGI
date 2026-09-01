use strict;
use warnings;

use Test2::V0;

use Cwd            qw{abs_path};
use File::Path     qw{make_path remove_tree};
use File::Temp     qw{tempdir};
use File::Basename qw{dirname};

use lib dirname( abs_path(__FILE__) ) . '/../lib';

use TPSGI::Startup;
use TPSGI;

my $tmp = tempdir( CLEANUP => 1 );

# A TPSGI object which is only good for logging & watching, as new() insists on
# being run as the configured user with a full config.
my $tpsgi = bless(
    {
        ip         => '127.0.0.1',
        user       => 'test',
        verbose    => 0,
        autoreload => 0,
        loggers    => [],
        log_dir    => "$tmp/log",
        log_name   => "$tmp/log/tpsgi.log",
        callbacks  => [],
    },
    'TPSGI'
);

# Give the kernel a moment to queue events, then drain.
sub changes {
    select( undef, undef, undef, 0.1 );
    return TPSGI::Startup::pending_changes();
}

subtest 'watching a file with a callback' => sub {
    my $file = "$tmp/subject.txt";
    open( my $fh, '>', $file ) or die $!;
    print $fh "initial\n";
    close $fh;

    my @fired;
    my $wd = $tpsgi->add_watch( $file, sub { my ( $t, $change ) = @_; push( @fired, $change ) } );
    ok( defined $wd,                       "add_watch returns a watch descriptor" );
    ok( TPSGI::Startup::is_watched($file), "path is now watched" );

    open( $fh, '>>', $file ) or die $!;
    print $fh "more\n";
    close $fh;

    $tpsgi->handle_changes();

    is( scalar(@fired),  1,     "callback fired once for one modification" );
    is( $fired[0]{path}, $file, "callback got the path which changed" );
    ok( ( grep { $_ eq 'MODIFY' } @{ $fired[0]{events} } ), "callback got decoded event names" );

    TPSGI::Startup::remove_watch($file);
    ok( !TPSGI::Startup::is_watched($file), "remove_watch drops the path" );

    @fired = ();
    open( $fh, '>>', $file ) or die $!;
    print $fh "even more\n";
    close $fh;
    $tpsgi->handle_changes();
    is( scalar(@fired), 0, "removed watches no longer fire" );
};

subtest 'registering the same callback repeatedly is idempotent' => sub {
    my $file = "$tmp/idempotent.txt";
    open( my $fh, '>', $file ) or die $!;
    close $fh;

    my @fired;
    my $cb = sub { push( @fired, $_[1] ) };

    # new() runs per request, so routers re-register their watches constantly.
    $tpsgi->add_watch( $file, $cb ) for 1 .. 5;

    my $wd = $TPSGI::Startup::watched{$file};
    is( scalar( @{ $TPSGI::Startup::watches{$wd}{callbacks} } ), 1, "callback registered exactly once" );

    open( $fh, '>>', $file ) or die $!;
    print $fh "poke\n";
    close $fh;
    $tpsgi->handle_changes();

    is( scalar(@fired), 1, "and it only fires once" );

    TPSGI::Startup::remove_watch($file);
};

subtest 'distinct callbacks on one path both fire, in order' => sub {
    my $file = "$tmp/multi.txt";
    open( my $fh, '>', $file ) or die $!;
    close $fh;

    my @fired;
    $tpsgi->add_watch( $file, sub { push( @fired, 'first' ) } );
    $tpsgi->add_watch( $file, sub { push( @fired, 'second' ) } );

    open( $fh, '>>', $file ) or die $!;
    print $fh "poke\n";
    close $fh;
    $tpsgi->handle_changes();

    is( \@fired, [qw{first second}], "both callbacks fired in registration order" );

    TPSGI::Startup::remove_watch($file);
};

subtest 'watching a directory reports the entries which changed' => sub {
    my $dir = "$tmp/watched_dir";
    make_path($dir);

    my @fired;
    $tpsgi->add_watch( $dir, sub { push( @fired, $_[1] ) } );

    open( my $fh, '>', "$dir/created.txt" ) or die $!;
    close $fh;
    $tpsgi->handle_changes();

    ok( scalar(@fired), "got at least one change for the directory" );
    is( $fired[0]{path},    "$dir/created.txt", "change path is the full path of the entry" );
    is( $fired[0]{watched}, $dir,               "change knows which watch it came from" );
    is( $fired[0]{name},    'created.txt',      "and the raw inotify name" );

    TPSGI::Startup::remove_watch($dir);
};

subtest 'watches survive a file being replaced wholesale' => sub {
    my $file = "$tmp/renamed.txt";
    open( my $fh, '>', $file ) or die $!;
    print $fh "one\n";
    close $fh;

    my @fired;
    my $original_wd = $tpsgi->add_watch( $file, sub { push( @fired, $_[1] ) } );

    # The write-a-tempfile-then-rename-over-it dance, which kills the old watch.
    open( $fh, '>', "$tmp/renamed.tmp" ) or die $!;
    print $fh "two\n";
    close $fh;
    rename( "$tmp/renamed.tmp", $file ) or die $!;

    $tpsgi->handle_changes();
    ok( scalar(@fired), "got the change which clobbered the file" );

    my $new_wd = $TPSGI::Startup::watched{$file};
    ok( defined $new_wd, "path is still watched afterwards" );
    is( scalar( @{ $TPSGI::Startup::watches{$new_wd}{callbacks} } ), 1, "callback survived the re-watch" );

    @fired = ();
    open( $fh, '>>', $file ) or die $!;
    print $fh "three\n";
    close $fh;
    $tpsgi->handle_changes();
    is( scalar(@fired), 1, "and still fires for changes to the new inode" );

    TPSGI::Startup::remove_watch($file);
};

subtest 'a dying callback does not take out the request' => sub {
    my $file = "$tmp/exploding.txt";
    open( my $fh, '>', $file ) or die $!;
    close $fh;

    my @fired;
    $tpsgi->add_watch( $file, sub { die "nope\n" },          key => 'boom' );
    $tpsgi->add_watch( $file, sub { push( @fired, 'ran' ) }, key => 'fine' );

    open( $fh, '>>', $file ) or die $!;
    print $fh "poke\n";
    close $fh;

    ok( lives { $tpsgi->handle_changes() }, "handle_changes survives a dying callback" );
    is( \@fired, ['ran'], "and still runs the other callbacks" );

    TPSGI::Startup::remove_watch($file);
};

subtest 'watching something which is not there is not fatal' => sub {
    my $wd;
    ok(
        lives {
            $wd = $tpsgi->add_watch( "$tmp/does_not_exist", sub { } )
        },
        "add_watch on a missing path lives"
    );
    is( $wd, undef, "and reports failure" );
    ok( !TPSGI::Startup::is_watched("$tmp/does_not_exist"), "nothing got registered" );
};

subtest 'libdir watches still drive autoreload' => sub {
    my $libdir = "$tmp/lib";
    make_path($libdir);
    open( my $fh, '>', "$libdir/Fake.pm" ) or die $!;
    print $fh "1;\n";
    close $fh;

    TPSGI::Startup::watch_for_changes($libdir);

    my $restarted = 0;
    no warnings qw{redefine once};
    local *TPSGI::signal_restart_parent = sub { $restarted++ };
    use warnings;

    open( $fh, '>>', "$libdir/Fake.pm" ) or die $!;
    print $fh "# poke\n";
    close $fh;

    local $tpsgi->{autoreload} = 1;
    $tpsgi->handle_changes();
    ok( $restarted, "a changed .pm in a libdir signals a restart" );

    # And the app-facing watches don't get roped into that.
    $restarted = 0;
    my $data = "$tmp/data.pm";
    open( $fh, '>', $data ) or die $!;
    close $fh;
    $tpsgi->add_watch( $data, sub { } );
    open( $fh, '>>', $data ) or die $!;
    print $fh "poke\n";
    close $fh;

    $tpsgi->handle_changes();
    ok( !$restarted, "but a .pm watched by an app does not" );

    TPSGI::Startup::remove_watch($data);
};

done_testing();
