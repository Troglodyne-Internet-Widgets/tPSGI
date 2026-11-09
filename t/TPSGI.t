#!/usr/bin/env perl
use 5.040;
use warnings FATAL => 'all';
use re '/aasx';

use Test2::V0;
use Test2::Plugin::NoWarnings;

use Cwd        ();
use File::Path ();
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

# The status, the headers and the body that a Range header gets for a file of
# ten bytes.
sub range_answer ($range) {
    my $tpsgi = bless( { %options, ip => '0.0.0.0' }, 'TPSGI' );
    my $file  = "$dir/ten-bytes";
    Mojo::File->new($file)->spew('0123456789');

    open( my $fh, '<', $file ) or die "Cannot read $file: $!";
    my $res = $tpsgi->serve_ranges( $fh, [ TPSGI::parse_ranges( { HTTP_RANGE => $range } ) ], size => 10, headers => { 'Content-type' => 'text/plain' }, fullpath => '/ten-bytes' );
    if ( ref $res eq 'ARRAY' ) {
        close($fh) or die "Cannot close: $!";
        return ( $res->[0], { @{ $res->[1] } }, undef );
    }

    my ( $status, %headers );
    my $body   = q{};
    my $writer = mock {} => ( add => [ write => sub ( $, $chunk ) { $body .= $chunk }, close => sub { } ] );
    $res->( sub ($head) { ( $status, %headers ) = ( $head->[0], @{ $head->[1] } ); return $writer } );
    return ( $status, \%headers, $body );
}

subtest 'serve_ranges, with a suffix range' => sub {
    my $answer = \&range_answer;

    my ( $status, $headers, $body ) = $answer->('bytes=-3');
    is( $status,                      206,            'bytes=-3 is a 206' );
    is( $body,                        '789',          'of the last three bytes' );
    is( $headers->{'Content-Range'},  'bytes 7-9/10', 'which Content-Range names' );
    is( $headers->{'Content-Length'}, 3,              'and Content-Length counts' );

    ( $status, $headers, $body ) = $answer->('bytes=-50');
    is( [ $status, $body, $headers->{'Content-Range'} ], [ 206, '0123456789', 'bytes 0-9/10' ], 'a suffix longer than the file is the whole file' );

    is( ( $answer->('bytes=-0') )[0],      416, 'bytes=-0 asks for nothing, so it is a 416' );
    is( ( $answer->('bytes=-') )[0],       416, 'bytes=- is a 416' );
    is( ( $answer->('bytes=abc-def') )[0], 416, 'and so is a range of words, which does not die' );
};

subtest 'serve_ranges, with a range past the end of the file' => sub {
    my ( $status, $headers, $body ) = range_answer('bytes=0-1048575');
    is( $status,                      206,            'a range that ends past the file is a 206' );
    is( $body,                        '0123456789',   'of the bytes up to the end' );
    is( $headers->{'Content-Range'},  'bytes 0-9/10', 'which Content-Range names, ending at the last byte' );
    is( $headers->{'Content-Length'}, 10,             'and Content-Length counts' );

    ( $status, $headers, $body ) = range_answer('bytes=8-20');
    is( [ $status, $body, $headers->{'Content-Range'}, $headers->{'Content-Length'} ], [ 206, '89', 'bytes 8-9/10', 2 ], 'a range that starts inside the file ends at its last byte' );

    ( $status, $headers, $body ) = range_answer('bytes=9-9');
    is( [ $status, $body ], [ 206, '9' ], 'the last byte alone is a 206' );

    is( ( range_answer('bytes=10-19') )[0], 416, 'a range that starts at the size is a 416' );
    is( ( range_answer('bytes=10-') )[0],   416, 'and so is one with no end' );

    ( $status, $headers, $body ) = range_answer('bytes=0-1,8-50');
    is( $status, 206, 'several ranges, one past the end, are a 206' );
    like( $body, qr/Content-Range:[ ]bytes[ ]8-9\/10\n\n89\n/, 'whose part names the range up to the last byte' );
    is( $headers->{'Content-Length'}, length $body, 'and Content-Length is the length of the body' );
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

subtest 'route' => sub {
    my $tpsgi = TPSGI->new( %new_options, routers => ['GoodRouter.pm'] );

    # The query that the callback of /post/x gets for $query_string.
    my $query_of = sub ($query_string) {
        my $match = $tpsgi->routes->match( 'GET', '/post/x' );
        my $got;
        $match->{callback} = sub ( $, $query ) { $got = $query; return [ 200, [], ['ok'] ] };
        my %env = ( REQUEST_METHOD => 'GET', ( defined $query_string ? ( QUERY_STRING => $query_string ) : () ) );
        $tpsgi->route( $match, \%env, fullpath => '/post/x', path => '/post/x', start => [ Time::HiRes::gettimeofday() ] );
        return $got;
    };

    my $query = $query_of->('limit=5');
    is( $query->{query_string}, 'limit=5', 'the callback gets the query string as the client sent it' );
    ok( $query->{has_query}, 'beside has_query' );

    is( $query_of->(undef)->{query_string}, q{}, 'a request without one gets an empty string, not undef' );
};

subtest 'respond, with a method that the path does not have' => sub {
    my $tpsgi = TPSGI->new( %new_options, routers => ['GoodRouter.pm'] );
    my $res   = $tpsgi->respond( { REQUEST_METHOD => 'POST', PATH_INFO => '/post/x', REQUEST_URI => '/post/x', HTTP_HOST => 'test.test' } );
    is( $res->[0],                   405,         'is a 405' );
    is( { @{ $res->[1] } }->{Allow}, 'GET, HEAD', 'which names the methods it has' );
};

subtest 'is_cgi' => sub {
    my $oldcwd = Cwd::getcwd();
    chdir $dir or die "Could not chdir to $dir: $!";

    # Every one of these is executable, as a restore or a checkout can leave an asset.
    File::Path::make_path(qw{www/cgi-bin/v1.2 www/cgi-bin-other www/assets});
    foreach my $file (qw{www/cgi-bin/run www/cgi-bin/v1.2/run www/cgi-bin/style.css www/cgi-bin-other/run www/assets/upload.pl www/assets/run}) {
        open( my $fh, '>', $file ) or die "Could not write $file: $!";
        close($fh)                 or die "Could not close $file: $!";
        chmod( 0o755, $file )      or die "Could not chmod $file: $!";
    }

    my $none = bless( {}, 'TPSGI' );
    is( $none->is_cgi('www/cgi-bin/run'), 0, 'with no cgi_dirs, nothing runs as a CGI, whatever its mode' );

    my $tpsgi = bless( { cgi_dirs => [ 'www/cgi-bin/', 'www/missing' ] }, 'TPSGI' );
    is( $tpsgi->is_cgi('www/cgi-bin/run'),       1, 'an executable inside a directory that cgi_dirs names runs, whatever slash ends the name' );
    is( $tpsgi->is_cgi('www//cgi-bin/run'),      1, 'and a path with a doubled slash is the same path' );
    is( $tpsgi->is_cgi('www/cgi-bin/v1.2/run'),  1, 'and a dot in a directory is no extension of the file' );
    is( $tpsgi->is_cgi('www/cgi-bin/style.css'), 0, 'but a file with no CGI extension there does not' );
    is( $tpsgi->is_cgi('www/assets/upload.pl'),  0, 'and an executable script outside them does not' );
    is( $tpsgi->is_cgi('www/assets/run'),        0, 'nor an executable with no extension' );
    is( $tpsgi->is_cgi('www/cgi-bin-other/run'), 0, 'nor one in a directory that only starts with the same name' );
    is( $tpsgi->is_cgi('www/cgi-bin/../assets/upload.pl'), 0, 'nor one that a path climbs to out of a directory that cgi_dirs names' );
    is( $tpsgi->is_cgi(undef),                   0, 'and no file is no CGI' );

    chdir $oldcwd or die "Could not chdir back to $oldcwd: $!";
};

done_testing();
