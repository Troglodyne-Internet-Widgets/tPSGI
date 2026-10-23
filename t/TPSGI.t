#!/usr/bin/env perl
use 5.040;
use warnings FATAL => 'all';
use re '/aasx';

use Test2::V0;
use Test2::Plugin::NoWarnings;

use File::Temp qw{tempdir};
use Mojo::File ();
use Test::MockModule;

use FindBin::libs;

use TPSGI;

# Every line the log gets, so a test can ask whether the reason for a 500 is
# among them.
package Test::Logger::Capture {
    use parent qw{Log::Dispatch::Output};

    our @lines;

    sub new {
        my ( $class, %p ) = @_;
        my $self = bless {}, $class;
        $self->_basic_init( name => 'capture', min_level => $p{min_level} );
        return $self;
    }

    sub log_message {
        my ( $self, %p ) = @_;
        push( @lines, $p{message} );
        return;
    }
}
local $INC{'Test/Logger/Capture.pm'} = __FILE__;

my $dir     = tempdir( CLEANUP => 1 );
my %options = (
    log_name => "$dir/tpsgi.log",
    log_dir  => $dir,
    verbose  => 0,
    loggers  => ['Test::Logger::Capture'],
);

sub fake_env {

    # The fake psgi.errors, which the caller keeps open.
    open( my $errors, '>', \my $written ) or die "Cannot open a scalar: $!";    ## no critic (RequireBriefOpen)
    return ( { 'psgi.errors' => $errors }, \$written );
}

# TPSGI builds its log once per process, so this has to run before anything
# else here builds it: a logger that will not load is only a failure the first
# time.
subtest 'cannot_start, when building the log is what failed' => sub {
    my ( $env, $written ) = fake_env();
    my $res;
    ok(
        lives { $res = TPSGI::cannot_start( "Could not load Bogus.pm!\n", $env, %options, loggers => ['Bogus::Logger::That::Is::Not'] ) },
        'a logger that will not load does not turn the 500 into an exception'
    ) or note $@;
    is( $res->[0], 500, 'it still answers 500' );
    like( $$written, qr/Could[ ]not[ ]load[ ]Bogus\.pm/, 'and psgi.errors still gets the reason' );
};

subtest 'cannot_start' => sub {
    local @Test::Logger::Capture::lines;
    my ( $env, $written ) = fake_env();

    my $res = TPSGI::cannot_start( "Could not load Bogus.pm!\nCan't locate Bogus/Dep.pm in \@INC\n", $env, %options );
    is( $res->[0], 500, 'answers 500' );
    like( $$written, qr/Can't[ ]locate[ ]Bogus\/Dep\.pm/, 'psgi.errors gets the whole reason' );
    my $reason = qr/Could[ ]not[ ]load[ ]Bogus[.]pm!/;
    like( \@Test::Logger::Capture::lines, bag { item qr/Could[ ]not[ ]start:[ ]$reason\nCan't[ ]locate/; etc() }, 'and so does the log' );

    ok( lives { TPSGI::cannot_start( "no env\n", undef, %options ) }, 'a missing env is not a second failure' ) or note $@;
};

subtest 'cannot_start retires the worker' => sub {
    my ($env) = fake_env();
    $env->{'psgix.harakiri'} = 1;
    TPSGI::cannot_start( "Could not load Bogus.pm!\n", $env, %options );
    ok( $env->{'psgix.harakiri.commit'}, 'a server that can retire the worker is told to' );

    ($env) = fake_env();
    TPSGI::cannot_start( "Could not load Bogus.pm!\n", $env, %options );
    ok( !exists $env->{'psgix.harakiri.commit'}, 'a server that cannot is not asked to' );
};

subtest 'cannot_start answers with a page' => sub {
    my $error = "Could not load Bogus.pm!\nCan't locate <Bogus/Dep.pm> in \@INC & \"elsewhere\"\n";

    my $res  = TPSGI::cannot_start( $error, ( fake_env() )[0], %options );
    my %head = @{ $res->[1] };
    is( $head{'Content-type'}, 'text/html', 'in HTML' );
    like( $res->[2][0], qr/<h1>Internal[ ]Server[ ]Error<\/h1>/, 'saying what happened' );
    unlike( $res->[2][0], qr/Bogus/, 'and, without TPSGI_DEBUG, not why' );

    local $TPSGI::debug = 1;
    $res = TPSGI::cannot_start( $error, ( fake_env() )[0], %options );
    my $escaped = q{Can't locate &#60;Bogus/Dep.pm&#62; in @INC &#38; &#34;elsewhere&#34;};
    like( $res->[2][0], qr/\Q$escaped\E/, 'with TPSGI_DEBUG, the error, escaped' );
    unlike( $res->[2][0], qr/<Bogus/, 'none of it read as markup' );
};

subtest 'app, when the request dies' => sub {
    local @Test::Logger::Capture::lines;
    my ( $env, $written ) = fake_env();

    my $mock = Test::MockModule->new( 'TPSGI', no_auto => 1 );
    $mock->redefine( respond => sub { die "Can't locate Bogus/Dep.pm in \@INC\n" } );

    my $tpsgi = bless( { %options, ip => '0.0.0.0' }, 'TPSGI' );
    my $res   = $tpsgi->app($env);

    is( $res->[0], 500, 'answers 500' );
    like( $$written,                      qr/Can't[ ]locate[ ]Bogus\/Dep\.pm/,                                         'psgi.errors gets the reason' );
    like( \@Test::Logger::Capture::lines, bag { item qr/Request[ ]failed:[ ]Can't[ ]locate[ ]Bogus\/Dep\.pm/; etc() }, 'and so does the log, not just that a 500 happened' );
};

subtest 'serve_ranges' => sub {
    local @Test::Logger::Capture::lines;
    my $tpsgi = bless( { %options, ip => '0.0.0.0' }, 'TPSGI' );

    my $file = "$dir/ten-bytes";
    Mojo::File->new($file)->spew('0123456789');
    my %args = ( size => 10, headers => { 'Content-type' => 'text/plain' }, fullpath => '/ten-bytes' );

    open( my $fh, '<', $file ) or die "Cannot read $file: $!";
    my $res = $tpsgi->serve_ranges( $fh, [ [ 0, 4 ] ], %args );
    is( ref $res,                                               'CODE', 'a range inside the file is streamed' );
    is( [ grep { /GET[ ]416/ } @Test::Logger::Capture::lines ], [],     'and not logged as a 416' );
    close($fh) or die "Cannot close: $!";

    open( $fh, '<', $file ) or die "Cannot read $file: $!";
    $res = $tpsgi->serve_ranges( $fh, [ [ 0, 4 ], [ 20, 25 ] ], %args );
    is( $res->[0], 416, 'a range past the end is refused' );
    like( \@Test::Logger::Capture::lines, bag { item qr/GET[ ]416[ ]\/ten-bytes/; etc() }, 'and logged as a 416' );
    close($fh) or die "Cannot close: $!";
};

# A router's pattern is matched as the router wrote it, whatever flags this
# distribution's own regexes carry.
subtest 'extract_query' => sub {
    my $tpsgi = bless( { %options, ip => '0.0.0.0' }, 'TPSGI' );
    my $env   = { REQUEST_METHOD => 'GET' };

    my $query = $tpsgi->extract_query( "/post/caf\N{LATIN SMALL LETTER E WITH ACUTE}", { pattern => '/post/(\w+)', captures => ['slug'] }, $env );
    is( $query->{slug}, "caf\N{LATIN SMALL LETTER E WITH ACUTE}", 'a \\w in a route matches a letter outside ASCII' );

    $query = $tpsgi->extract_query( '/a b/c', { pattern => '/a b/(\w+)', captures => ['name'] }, $env );
    is( $query->{name}, 'c', 'and a space in a route is a space' );

    $query = $tpsgi->extract_query( "/note/x\ny", { pattern => '/note/(.+)', captures => ['text'] }, $env );
    is( $query->{text}, undef, 'and a dot does not match a newline' );
};

done_testing();
