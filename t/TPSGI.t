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

# Writes a router module into $dir, and returns its name relative to $dir.
sub write_router {
    my ( $package, $body ) = @_;
    Mojo::File->new("$dir/$package.pm")->spew("package $package;\nuse 5.040;\n$body\n1;\n");
    return "$package.pm";
}

my %new_options = (
    %options,
    user      => scalar getpwuid($>),
    http_user => scalar getgrgid( ( getpwuid($>) )[3] ),
    tpsgi_dir => $dir,
);

subtest 'new' => sub {
    my $stale = write_router( 'StaleRouter', q{our @routes = ( '/x' => { method => 'GET', callbacks => { '*' => sub { } } } );} );
    like(
        dies { TPSGI->new( %new_options, routers => [$stale] ) },
        qr/StaleRouter[.]pm[ ]defines[ ]\@routes[ ]and[ ]no/,
        'a router that still has @routes dies as it loads'
    );

    my $router = write_router( 'GoodRouter', <<~'ROUTER' );
        our %openapi = (
            openapi => '3.0.3',
            info    => { title => 'good', version => '1' },
            paths   => {
                '/post/{slug}' => {
                    get => {
                        'x-tpsgi-callback' => sub { },
                        'x-tpsgi-data'     => { from => 'data' },
                        parameters         => [
                            { name => 'slug',  in => 'path',  required => true, schema => { type => 'string' } },
                            { name => 'limit', in => 'query', schema   => { type => 'integer' } },
                        ],
                        responses => { 200 => { description => 'ok' } },
                    },
                },
            },
        );
        ROUTER
    my $first = TPSGI->new( %new_options, routers => [$router] );
    is( $first->routes->match( 'GET', '/post/hello' )->{template}, '/post/{slug}', 'a router with %openapi routes' );
    ref_is( TPSGI->new( %new_options, routers => [$router] )->routes, $first->routes, 'and the next request in the worker reuses the router' );
};

subtest 'extract_query' => sub {
    my $tpsgi = TPSGI->new( %new_options, routers => ['GoodRouter.pm'] );
    my $env   = { REQUEST_METHOD => 'GET' };
    my $cafe  = "caf\N{LATIN SMALL LETTER E WITH ACUTE}";

    my $query = $tpsgi->extract_query( "/post/$cafe", $tpsgi->routes->match( 'GET', "/post/$cafe" ), $env );
    is( $query->{slug}, $cafe,  'a path parameter, outside ASCII too, is in the query' );
    is( $query->{from}, 'data', 'and so is x-tpsgi-data' );

    $query = $tpsgi->extract_query( '/post/x', $tpsgi->routes->match( 'GET', '/post/x' ), { %$env, QUERY_STRING => 'limit=5' } );
    is( $query->{limit}, 5,   'the query string is in the query' );
    is( $query->{slug},  'x', 'beside the path parameter' );

    local @Test::Logger::Capture::lines;
    my $res = $tpsgi->extract_query( '/post/x', $tpsgi->routes->match( 'GET', '/post/x' ), { %$env, QUERY_STRING => 'limit=many' } );
    is( ref $res,  'ARRAY', 'a query that fails validation is an answer, not a query' );
    is( $res->[0], 400,     'a 400' );
    unlike( $res->[2][0], qr/integer/, 'which does not say why' );

    $res = $tpsgi->extract_query( '/post/x', $tpsgi->routes->match( 'GET', '/post/x' ), { %$env, QUERY_STRING => 'junk=1' } );
    is( $res->[0], 400, 'and so is one with a key that the operation does not declare' );

    $res = $tpsgi->extract_query( '/post/x', $tpsgi->routes->match( 'GET', '/post/x' ), { %$env, QUERY_STRING => 'slug=y' } );
    is( $res->[0], 400, 'even when the path declares it' );
};

subtest 'respond, with a method that the path does not have' => sub {
    my $tpsgi = TPSGI->new( %new_options, routers => ['GoodRouter.pm'] );
    my $res   = $tpsgi->respond( { REQUEST_METHOD => 'POST', PATH_INFO => '/post/x', REQUEST_URI => '/post/x', HTTP_HOST => 'test.test' } );
    is( $res->[0],                   405,         'is a 405' );
    is( { @{ $res->[1] } }->{Allow}, 'GET, HEAD', 'which names the methods it has' );
};

done_testing();
