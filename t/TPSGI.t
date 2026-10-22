use strict;
use warnings;

use Test2::V0;
use Test2::Plugin::NoWarnings;

use Cwd            qw{abs_path};
use File::Temp     qw{tempdir};
use File::Basename qw{dirname};
use Test::MockModule;

use lib dirname( abs_path(__FILE__) ) . '/../lib';

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
$INC{'Test/Logger/Capture.pm'} = __FILE__;

my $dir     = tempdir( CLEANUP => 1 );
my %options = (
    log_name => "$dir/tpsgi.log",
    log_dir  => $dir,
    verbose  => 0,
    loggers  => ['Test::Logger::Capture'],
);

sub fake_env {
    open( my $errors, '>', \my $written ) or die "Cannot open a scalar: $!";
    return ( { 'psgi.errors' => $errors }, \$written );
}

# TPSGI builds its log once per process, so this has to run before anything
# else here builds it: a logger that will not load is only a failure the first
# time.
subtest 'cannot_start, when building the log is what failed' => sub {
    my ( $env, $written ) = fake_env();
    my $res;
    ok( lives { $res = TPSGI::cannot_start( "Could not load Bogus.pm!\n", $env, %options, loggers => ['Bogus::Logger::That::Is::Not'] ) },
        'a logger that will not load does not turn the 500 into an exception' )
      or note $@;
    is( $res->[0], 500, 'it still answers 500' );
    like( $$written, qr/Could not load Bogus\.pm/, 'and psgi.errors still gets the reason' );
};

subtest 'cannot_start' => sub {
    local @Test::Logger::Capture::lines;
    my ( $env, $written ) = fake_env();

    my $res = TPSGI::cannot_start( "Could not load Bogus.pm!\nCan't locate Bogus/Dep.pm in \@INC\n", $env, %options );
    is( $res->[0], 500, 'answers 500' );
    like( $$written,                       qr/Can't locate Bogus\/Dep\.pm/,                     'psgi.errors gets the whole reason' );
    like( \@Test::Logger::Capture::lines, bag { item qr/Could not start: Could not load Bogus\.pm!\nCan't locate/; etc() }, 'and so does the log' );

    ok( lives { TPSGI::cannot_start( "no env\n", undef, %options ) }, 'a missing env is not a second failure' ) or note $@;
};

subtest 'cannot_start retires the worker' => sub {
    my ( $env ) = fake_env();
    $env->{'psgix.harakiri'} = 1;
    TPSGI::cannot_start( "Could not load Bogus.pm!\n", $env, %options );
    ok( $env->{'psgix.harakiri.commit'}, 'a server that can retire the worker is told to' );

    ( $env ) = fake_env();
    TPSGI::cannot_start( "Could not load Bogus.pm!\n", $env, %options );
    ok( !exists $env->{'psgix.harakiri.commit'}, 'a server that cannot is not asked to' );
};

subtest 'cannot_start answers with a page' => sub {
    my $error = "Could not load Bogus.pm!\nCan't locate <Bogus/Dep.pm> in \@INC & \"elsewhere\"\n";

    my $res  = TPSGI::cannot_start( $error, ( fake_env() )[0], %options );
    my %head = @{ $res->[1] };
    is( $head{'Content-type'}, 'text/html', 'in HTML' );
    like( $res->[2][0], qr/<h1>Internal Server Error<\/h1>/, 'saying what happened' );
    unlike( $res->[2][0], qr/Bogus/, 'and, without TPSGI_DEBUG, not why' );

    local $TPSGI::debug = 1;
    $res = TPSGI::cannot_start( $error, ( fake_env() )[0], %options );
    like( $res->[2][0], qr/Can't locate &#60;Bogus\/Dep\.pm&#62; in \@INC &#38; &#34;elsewhere&#34;/, 'with TPSGI_DEBUG, the error, escaped' );
    unlike( $res->[2][0], qr/<Bogus/, 'none of it read as markup' );
};

subtest 'app, when the request dies' => sub {
    local @Test::Logger::Capture::lines;
    my ( $env, $written ) = fake_env();

    my $mock = Test::MockModule->new( 'TPSGI', no_auto => 1 );
    $mock->redefine( _app => sub { die "Can't locate Bogus/Dep.pm in \@INC\n" } );

    my $tpsgi = bless( { %options, ip => '0.0.0.0' }, 'TPSGI' );
    my $res   = $tpsgi->app($env);

    is( $res->[0], 500, 'answers 500' );
    like( $$written,                       qr/Can't locate Bogus\/Dep\.pm/,                                'psgi.errors gets the reason' );
    like( \@Test::Logger::Capture::lines, bag { item qr/Request failed: Can't locate Bogus\/Dep\.pm/; etc() }, 'and so does the log, not just that a 500 happened' );
};

done_testing();
