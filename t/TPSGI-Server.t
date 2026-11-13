#!/usr/bin/env perl
use 5.040;
use warnings FATAL => 'all';
use re '/aasx';

use Test2::V0;
use Test2::Plugin::NoWarnings;

use Test::MockModule;
use Time::HiRes ();

use FindBin::libs;

ok( require TPSGI::Server, 'TPSGI::Server loads' ) or bail_out("Can't find SUT");

sub server {
    my (%server) = @_;
    return bless( { server => \%server }, 'TPSGI::Server' );
}

subtest 'child_init_hook' => sub {
    my $starman = Test::MockModule->new('Starman::Server');
    my $built   = 0;
    $starman->redefine( child_init_hook => sub { $built++ } );

    local $SIG{HUP} = sub { fail('the handler Net::Server installed ran') };
    my $self = server( connected => 0 );
    $self->child_init_hook();
    is( $built, 1, "Starman's hook still runs, so the app is built" );

    $SIG{HUP}->();
    is( $self->{server}{SigHUPed}, 1, 'a HUP marks the worker HUPed, which done() retires it for' );
    is( $self->{server}{_HUP},     1, 'and makes accept() return instead of retrying' );
};

subtest 'accept' => sub {
    my $net = Test::MockModule->new('Net::Server::PreForkSimple');

    # What Net::Server::accept() does when the HUP lands as it takes a
    # connection: it has the client, and returns 0 because _HUP is set.
    $net->redefine( accept => sub { $_[0]{server}{client} = 'a connection'; return 0 } );
    is( server()->accept(), 1, 'a connection accepted as the HUP came is answered' );

    # And when the HUP interrupts the wait, with nothing taken.
    $net->redefine( accept => sub { return 0 } );
    is( server( client => 'the last request' )->accept(), 0, 'a worker that took nothing retires, whatever its last request left behind' );

    $net->redefine( accept => sub { $_[0]{server}{client} = 'a connection'; return 1 } );
    is( server()->accept(), 1, 'an ordinary accept is passed through' );
};

subtest 'pre_loop_hook and sig_hup' => sub {
    my $startup = Test::MockModule->new('TPSGI::Startup');
    my @swept;
    $startup->redefine( get_config    => sub { return ( tpsgi_dir => '/bogus', basedir => 'app' ) } );
    $startup->redefine( sweep_statics => sub (%options) { push @swept, \%options; return ('/bogus/www/static/stale.css') } );

    my $starman = Test::MockModule->new('Starman::Server');
    my @ran;
    $starman->redefine( pre_loop_hook => sub { push @ran, [ pre_loop_hook => scalar @swept ]; return 'started' } );
    $starman->redefine( sig_hup       => sub { push @ran, [ sig_hup       => scalar @swept ]; return 'hupped' } );

    my $net = Test::MockModule->new('Net::Server');
    my @logged;
    $net->redefine( log => sub ( $, $level, $message ) { push @logged, $message } );

    my $self = server();
    is( $self->pre_loop_hook(), 'started',                                                        "the parent starts as Starman's does" );
    is( $self->sig_hup(),       'hupped',                                                         "and takes a HUP as Starman's does" );
    is( \@ran,                  [ [ pre_loop_hook => 1 ], [ sig_hup => 2 ] ],                     'after a sweep of the statics, each time' );
    is( $swept[0],              { tpsgi_dir => '/bogus', basedir => 'app', renders => 1 },        'of the install that the configuration names, with its renders when it starts' );
    is( $swept[1],              { tpsgi_dir => '/bogus', basedir => 'app' },                      'but without them at a HUP, which an application sends when it saves its data' );
    is( \@logged,               [ ('Removed the stale static /bogus/www/static/stale.css') x 2 ], 'and it logs each static that it removed' );
};

subtest 'every connection is answered while the parent is HUPed' => sub {
    skip_all('RELEASE_TESTING not set') unless $ENV{RELEASE_TESTING};

    require File::Temp;
    require Mojo::File;
    require IO::Socket::UNIX;
    require Plack::Handler::TPSGI;

    my $dir  = File::Temp::tempdir( CLEANUP => 1 );
    my $sock = "$dir/s.sock";

    my $server = fork() // die "fork: $!";
    if ( !$server ) {
        close(STDERR) or die "Cannot close STDERR: $!";
        Plack::Handler::TPSGI->new( listen => [$sock], workers => 5, pid => "$dir/pid", keepalive => 0 )->run( sub { [ 200, [ 'Content-Type' => 'text/plain' ], ['ok'] ] } );
        exit 0;
    }
    for ( 1 .. 100 ) { last if -S $sock && -s "$dir/pid"; Time::HiRes::sleep(0.1) }
    ok( -S $sock, 'the server is listening' ) or return;
    my $parent = Mojo::File->new("$dir/pid")->slurp;
    chomp $parent;

    # Four clients, each counting the requests that got no answer.
    my @clients = map {
        my $pid = fork() // die "fork: $!";
        if ( !$pid ) {
            my $bad = 0;
            for ( 1 .. 1500 ) {
                my $c = IO::Socket::UNIX->new( Peer => $sock ) or do { $bad++; next };
                print {$c} "GET / HTTP/1.0\r\n\r\n";
                my $got = do { local $/; <$c> }
                  // '';
                $bad++ unless $got =~ m{^HTTP/1[.]\d[ ]200};
            }
            exit( $bad > 255 ? 255 : $bad );
        }
        $pid
    } 1 .. 4;

    for ( 1 .. 60 ) { kill( 'HUP', $parent ); Time::HiRes::sleep(0.05) }

    my $unanswered = 0;
    foreach my $pid (@clients) { waitpid( $pid, 0 ); $unanswered += $? >> 8 }
    is( $unanswered, 0, 'no request of 6000 went unanswered across 60 restarts' );

    kill( 'TERM', $parent );
    waitpid( $server, 0 );
};

done_testing();
