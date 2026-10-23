#!/usr/bin/env perl
use 5.040;
use warnings FATAL => 'all';
use re '/aasx';

use Test2::V0;
use Test2::Plugin::NoWarnings;

use Mojo::JSON ();

use FindBin::libs;

use TPSGI::Router;

sub named { return 'named' }

sub coderef { return 'coderef' }

sub path_parameter {
    my ( $name, %schema ) = @_;
    return { name => $name, in => 'path', required => Mojo::JSON::true, schema => { type => 'string', %schema } };
}

sub operation {
    my (%operation) = @_;
    return { 'x-tpsgi-callback' => \&coderef, responses => { 200 => { description => 'ok' } }, %operation };
}

sub document {
    my (%paths) = @_;
    return { openapi => '3.0.3', info => { title => 'test', version => '1' }, paths => \%paths };
}

my $router = TPSGI::Router->new(
    'Test.pm' => document(
        '/sitemap/static.xml'    => { get => operation() },
        '/sitemap/{map}.xml'     => { get => operation( parameters => [ path_parameter('map') ] ) },
        '/sitemap/{map}.xml.gz'  => { get => operation( parameters => [ path_parameter('map') ] ) },
        '/lib/{module+}'         => { get => operation( parameters => [ path_parameter('module+') ] ) },
        '/lib/index'             => { get => operation() },
        '/{year}-{month}/{slug}' => { get => operation( parameters         => [ map { path_parameter($_) } qw{year month slug} ] ) },
        '/humans.txt'            => { get => operation( 'x-tpsgi-callback' => 'main::named' ) },
        '/post/{slug}'           => { get => operation( parameters         => [ path_parameter('slug') ] ) },
        '/form'                  => {
            post => operation(
                requestBody => {
                    content => {
                        'application/x-www-form-urlencoded' => {
                            schema => {
                                type                 => 'object',
                                additionalProperties => Mojo::JSON::false,
                                properties           => { count => { type => 'integer' } },
                            },
                        },
                    },
                },
            ),
        },
        '/search' => {
            get => operation(
                parameters => [
                    { name => 'limit', in => 'query', schema => { type => 'integer' } },
                    { name => 'exact', in => 'query', schema => { type => 'boolean' } },
                ],
            ),
        },
        '/loose'            => { get => operation() },
        '/news/{slug}'      => { get => operation( parameters => [ path_parameter('slug') ] ) },
        '/{section}/latest' => { get => operation( parameters => [ path_parameter('section') ] ) },
    ),
);

subtest 'a literal template wins over a variable' => sub {
    is( $router->match( 'GET', '/sitemap/static.xml' )->{template}, '/sitemap/static.xml', 'the static sitemap is the static route' );
    my $route = $router->match( 'GET', '/sitemap/1.xml' );
    is( $route->{template},                                       '/sitemap/{map}.xml',    'and any other reaches the template' );
    is( $route->{path},                                           { map => 1 },            'with the variable' );
    is( $router->match( 'GET', '/sitemap/1.xml.gz' )->{template}, '/sitemap/{map}.xml.gz', 'and the compressed one its own template' );
    is( $router->match( 'GET', '/lib/index' )->{template},        '/lib/index',            'a literal path wins over {name+}' );
    is( $router->match( 'GET', '/news/latest' )->{template},      '/news/{slug}',          'and an earlier literal segment wins over more literal characters' );
};

subtest 'variables' => sub {
    my $route = $router->match( 'GET', '/2026-10/hello' );
    is( $route->{path}, { year => 2026, month => 10, slug => 'hello' }, 'two variables in one segment' );

    $route = $router->match( 'GET', '/lib/Trog/Auth.html' );
    is( $route->{path}, { module => 'Trog/Auth.html' }, '{module+} takes the rest of the path, slashes and all, as module' );

    my $cafe = "caf\N{LATIN SMALL LETTER E WITH ACUTE}";
    is( $router->match( 'GET', "/post/$cafe" )->{path}, { slug => $cafe }, 'a variable takes a letter outside ASCII' );
    is( $router->match( 'GET', "/post/a\nb" ),          undef,             'and no newline' );
    is( $router->match( 'GET', '/post/a/b' ),           undef,             'and no slash' );
    is( $router->match( 'GET', "/lib/a\nb" ),           undef,             'nor does {name+} take a newline' );
};

subtest 'a literal character is only itself' => sub {
    is( $router->match( 'GET', '/humans.txt' )->{template}, '/humans.txt', 'the dot matches a dot' );
    is( $router->match( 'GET', '/humansXtxt' ),             undef,         'and nothing else' );
    is( $router->match( 'GET', '/sitemap/1Xxml' ),          undef,         'in a segment with a variable as well' );
};

subtest 'callbacks' => sub {
    is( $router->match( 'GET', '/loose' )->{callback}->(),      'coderef', 'a CODE reference is the callback' );
    is( $router->match( 'GET', '/humans.txt' )->{callback}->(), 'named',   'and a name is resolved to its sub' );

    like(
        dies { TPSGI::Router->new( 'Bad.pm' => document( '/x' => { get => { responses => { 200 => { description => 'ok' } } } } ) ) },
        qr/Bad[.]pm:[ ]GET[ ]\/x[ ]has[ ]no[ ]x-tpsgi-callback/,
        'an operation without a callback dies'
    );
    like(
        dies { TPSGI::Router->new( 'Bad.pm' => document( '/x' => { get => operation( 'x-tpsgi-callback' => 'main::no_such_sub' ) } ) ) },
        qr/no_such_sub,[ ]which[ ]is[ ]not[ ]a[ ]defined/,
        'and so does a name that is not a sub'
    );
};

subtest 'documents that are refused' => sub {
    like(
        dies { TPSGI::Router->new( 'Bad.pm' => { openapi => '3.0.3', paths => {} } ) },
        qr/is[ ]not[ ]a[ ]valid[ ]OpenAPI[ ]3[ ]document/,
        'an invalid document dies with the reason'
    );
    like(
        dies { TPSGI::Router->new( 'Bad.pm' => document( '/a/{x}' => { get => operation() }, '/a/{y}' => { post => operation() } ) ) },
        qr/[}][ ]and[ ]\/a\/[{].[}][ ]match[ ]the[ ]same/,
        'two templates that differ only in their variable names die'
    );
    like(
        dies { TPSGI::Router->new( 'One.pm' => document( '/a' => { get => operation() } ), 'Two.pm' => document( '/a' => { get => operation() } ) ) },
        qr/Two[.]pm:[ ]GET[ ]\/a[ ]is[ ]also[ ]a[ ]route/,
        'one template and method in two routers dies'
    );
    ok(
        lives { TPSGI::Router->new( 'One.pm' => document( '/a' => { get => operation() } ), 'Two.pm' => document( '/a' => { post => operation() } ) ) },
        'but two methods of one template in two routers do not'
    ) or note $@;
    like( dies { TPSGI::Router::compile_template('/a/{x+}/b') }, qr/not[ ]the[ ]whole[ ]last[ ]segment/, '{name+} before the last segment dies' );
    like( dies { TPSGI::Router::compile_template('/a/b{x+}') },  qr/not[ ]the[ ]whole[ ]last[ ]segment/, 'and so does {name+} with text beside it' );
    like( dies { TPSGI::Router::compile_template('/a/{x') },     qr/a[ ]brace[ ]that[ ]is[ ]not/,        'and a brace that is not a variable' );
};

subtest 'methods' => sub {
    is( $router->match( 'HEAD', '/loose' )->{method}, 'get', 'HEAD falls back to get' );

    my $route = $router->match( 'POST', '/loose' );
    is( $route->{status},                    405,            'a path whose template has no operation for the method is a 405' );
    is( $route->{allow},                     [qw{GET HEAD}], 'which names the methods it does have' );
    is( $router->match( 'GET', '/nowhere' ), undef,          'and a path that no template matches is nothing at all' );
};

subtest 'validation' => sub {
    my $route = $router->match( 'GET', '/search' );
    my %query = ( limit => '5', exact => 'true' );
    is( [ $router->validate( $route, query => \%query ) ], [],                         'a valid query passes' );
    is( Mojo::JSON::encode_json( \%query ),                '{"exact":true,"limit":5}', 'and arrives coerced: a number and a boolean, not two strings' );

    my ( $status, @errors ) = $router->validate( $route, query => { limit => 'many' } );
    is( $status, 400, 'a value that its schema refuses is a 400' );
    like( \@errors, [qr/\/limit:[ ]Expected[ ]integer/], 'for that reason' );

    ( $status, @errors ) = $router->validate( $route, query => { limit => 1, junk => 1 } );
    is( $status, 400, 'an undeclared query key is a 400' );
    like( \@errors, [qr/\/junk:/], 'and named' );
    is( [ $router->validate( $route,                            query => { limit    => 1, route => '/x' } ) ], [], 'except a key that tPSGI sets itself' );
    is( [ $router->validate( $router->match( 'GET', '/loose' ), query => { anything => 1 } ) ],                [], 'and an operation that declares nothing takes anything' );

    $route = $router->match( 'POST', '/form' );
    my $form_type = 'application/x-www-form-urlencoded';
    is( [ $router->validate( $route, body => { count => '3' }, content_type => $form_type ) ], [], 'a form that its schema takes passes' );
    ( $status, @errors ) = $router->validate( $route, body => { count => 3, junk => 1 }, content_type => $form_type );
    is( $status, 400, 'a form key that additionalProperties refuses is a 400' );
    like( \@errors, [qr/Properties[ ]not[ ]allowed:[ ]junk/], 'for that reason' );
    ( $status, @errors ) = $router->validate( $route, body => { count => 3 }, content_type => 'text/plain' );
    is( $status,                                                                                              415, 'a body of a media type the operation does not take is a 415' );
    is( [ $router->validate( $route, body => { count => 3 }, content_type => "$form_type; charset=UTF-8" ) ], [],  'and parameters of the media type do not count' );
};

subtest 'precedence' => sub {
    my @order = map { $_->{template} } grep { index( $_->{template}, '/sitemap/' ) == 0 || index( $_->{template}, '/lib/' ) == 0 } $router->routes();
    is( \@order, [qw{/lib/index /sitemap/static.xml /sitemap/{map}.xml.gz /sitemap/{map}.xml /lib/{module+}}], 'literal routes first, then by segment, then by literal length' );
};

done_testing();
