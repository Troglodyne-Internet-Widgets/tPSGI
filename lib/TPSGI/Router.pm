package TPSGI::Router;

# ABSTRACT: Match requests to the operations of OpenAPI 3 documents, and validate them

use 5.040;
use warnings FATAL => 'all';
use re '/aasx';

use List::Util ();
use JSON::Validator::Schema::OpenAPIv3;
use JSON::Validator::Util ();
use Cpanel::JSON::XS      ();

=head1 SYNOPSIS

    my $router = TPSGI::Router->new( 'lib/My/Routes.pm' => \%My::Routes::openapi );

    sub answer {
        my ( $tpsgi, $method, $path, %query ) = @_;

        my $request = { method => $method, fullpath => $path };
        my $route   = $router->match( $method, $path );
        return $tpsgi->notfound($request) unless $route;
        return $tpsgi->notallowed( $request, @{ $route->{allow} } ) if $route->{status};

        my ( $status, @errors ) = $router->validate( $route, query => \%query );
        return $tpsgi->badrequest($request) if $status;
        return $route->{callback}->( $tpsgi, { %query, %{ $route->{path} } } );
    }

=head1 DESCRIPTION

TPSGI::Router compiles the C<%openapi> document of each router once.  Then it
answers which operation a request is for, and whether the request is valid for
that operation.

Each key of C<paths> is a template.  A template is a list of segments, which
slashes separate.  A segment is made of literal text and variables:

=over

=item C<{name}> is any text up to the next slash.  One segment can hold several
variables and literal text, for example C<{map}.xml>.

=item C<{name+}> is the rest of the path, slashes and all.  It must be the whole
last segment, as in C</lib/{module+}>.  Declare its parameter with the name
C<name+>.  The query gives its value to the callback as C<name>.

=back

A literal character matches only itself, so the C<.> of C</humans.txt> matches
only a dot.  No variable matches a newline.

When more than one template matches a path, the most concrete one wins.  The
segments are compared in order.  A literal segment comes first, then a segment
of literal text and variables, then a lone C<{name}>, then a C<{name+}>.  If
that does not decide, the template with more literal characters wins, and then
the template that sorts first as a string.  So the order never depends on the
order of a hash.

=cut

my @methods = qw{get put post delete options head patch trace};

# The keys of the query that tPSGI sets itself.  The query string can hold
# them without a 400, because route() replaces them anyway.
my @reserved = qw{tpsgi ip ua user referer route dispatcher};

# How concrete a segment is.  A lower rank wins.
my %rank = (
    literal => 0,
    mixed   => 1,
    single  => 2,
    rest    => 3,
);

=head1 METHODS

=head2 new(@pairs) = TPSGI::Router

Compile the documents.  @pairs is a list of names and documents, for example
the file of each router and its C<%openapi>.  The name goes into each error.

new() dies with the reason when a document is not valid OpenAPI 3, when an
operation has no C<x-tpsgi-callback>, or when its callback is a name that is
not a defined sub.  It also dies on two templates that differ only in the names
of their variables, and on one template and method in two documents.

=cut

sub new {
    my ( $class, @pairs ) = @_;

    my $self = bless( { by_template => {}, shapes => {}, exact => {} }, $class );
    while ( my ( $name, $document ) = splice( @pairs, 0, 2 ) ) {
        $self->add_document( $name, $document );
    }

    my @templated = grep { !$_->{literal} } values( %{ $self->{by_template} } );
    $self->{templated} = [ sort { by_precedence( $a, $b ) } @templated ];
    $self->{exact}{ $_->{template} } = $_ for grep { $_->{literal} } values( %{ $self->{by_template} } );

    return $self;
}

=head2 json_booleans($data) = copy

A copy of $data in which each of perl's own booleans, such as the C<true> that
C<use 5.040> gives a router, is a Cpanel::JSON::XS boolean.  JSON::Validator
5.19 compares C<enum> values by a checksum, so a native true does not equal
the true of the OpenAPI schema, and C<required =E<gt> true> fails.  Hashes and
arrays are copied.  Every other reference is kept, so a callback stays the
same sub.

=cut

sub json_booleans {
    my ($data) = @_;
    no warnings qw{experimental::builtin};

    # Each job is the place a copy goes, and what to copy there.
    my $copy;
    my @todo = ( [ \$copy, $data ] );
    while ( my $job = shift @todo ) {
        my ( $slot, $value ) = @$job;
        if ( ref $value eq 'HASH' ) {
            $$slot = {};
            push( @todo, map { [ \$$slot->{$_}, $value->{$_} ] } keys(%$value) );
        }
        elsif ( ref $value eq 'ARRAY' ) {
            $$slot = [];
            push( @todo, map { [ \$$slot->[$_], $value->[$_] ] } 0 .. $#$value );
        }
        elsif ( !ref $value && builtin::is_bool($value) ) {
            $$slot = $value ? Cpanel::JSON::XS::true : Cpanel::JSON::XS::false;
        }
        else {
            $$slot = $value;
        }
    }
    return $copy;
}

=head2 add_document($name, $document)

Check $document as OpenAPI 3, and add each of its operations.  new() calls it
for each pair.

=cut

sub add_document {
    my ( $self, $name, $document ) = @_;

    die "$name: the router's %openapi is not a HASH reference\n" unless ref $document eq 'HASH';

    my $schema = JSON::Validator::Schema::OpenAPIv3->new( json_booleans($document) );
    my @errors = @{ $schema->errors };
    die "$name: %openapi is not a valid OpenAPI 3 document:\n" . join( "\n", map { "  $_" } @errors ) . "\n" if @errors;

    my $paths = $schema->get( ['paths'] ) // {};
    foreach my $template ( sort keys(%$paths) ) {
        my $matcher = $self->matcher_for( $name, $template );
        foreach my $method ( grep { exists $paths->{$template}{$_} } @methods ) {
            die "$name: \U$method\E $template is also a route of $matcher->{methods}{$method}{router}\n" if $matcher->{methods}{$method};

            my $operation = $paths->{$template}{$method};
            $matcher->{methods}{$method} = {
                router    => $name,
                template  => $template,
                method    => $method,
                operation => $operation,
                schema    => $schema,
                callback  => resolve_callback( "$name: \U$method\E $template", $operation->{'x-tpsgi-callback'} ),
                %{ $self->rules_for( $schema, $method, $template ) },
            };
        }
    }
    return;
}

=head2 matcher_for($name, $template) = HASHREF

The compiled form of $template, made the first time it is asked for.  It dies
when $template is not a template, and when another template differs from it
only in the names of its variables.

=cut

sub matcher_for {
    my ( $self, $name, $template ) = @_;

    return $self->{by_template}{$template} if $self->{by_template}{$template};

    my $matcher = compile_template($template);
    my $twin    = $self->{shapes}{ $matcher->{shape} };
    die "$name: $template and $twin match the same paths, and differ only in the names of their variables\n" if $twin;
    $self->{shapes}{ $matcher->{shape} } = $template;

    return $self->{by_template}{$template} = $matcher;
}

=head2 compile_template($template) = HASHREF

A function.  The compiled form of $template: its regular expression, the names of
its variables, the rank of each segment, its count of literal characters, and
its shape, which is the template with every variable name left out.  It dies
when the template does not start with a slash, when a brace is not part of a
variable, and when a C<{name+}> is not the whole last segment.

=cut

sub compile_template {
    my ($template) = @_;

    die "The template $template does not start with a slash\n" unless index( $template, '/' ) == 0;

    my @segments = split( m{/}, substr( $template, 1 ), -1 );
    my ( @regex, @ranks, @variables );
    my $literal_length = 0;
    my $shape          = '';

    foreach my $i ( 0 .. $#segments ) {
        my $segment = $segments[$i];
        my @parts   = $segment =~ m/ ( \{ [^{}]* \} | [^{}]+ ) /g;
        die "The template $template has a brace that is not part of a {variable}\n" unless join( '', @parts ) eq $segment;

        my ( $regex, $variables ) = ( '', 0 );
        foreach my $part (@parts) {
            my ($variable) = $part =~ m/ \A \{ ( [^{}]+ ) \} \z /;
            if ( !defined $variable ) {
                $regex .= quotemeta($part);
                $shape .= $part;
                $literal_length += length($part);
                next;
            }
            $variables++;
            my $is_rest = $variable =~ s/ [+] \z //;
            die "The template $template has an empty {variable}\n"                        if $variable eq '';
            die "In the template $template, {$variable+} is not the whole last segment\n" if $is_rest && ( @parts > 1 || $i < $#segments );

            # \N, so that no variable takes a newline that a %0A decoded to.
            $regex .= $is_rest ? '(\N+)' : '([^/\n]+?)';
            $shape .= $is_rest ? '{+}'   : '{}';
            push( @variables, $variable );
        }
        $shape .= '/' if $i < $#segments;

        my $kind = !$variables ? 'literal' : @parts > 1 ? 'mixed' : $regex eq '(\N+)' ? 'rest' : 'single';
        push( @ranks, $rank{$kind} );
        push( @regex, $regex );
    }

    my $source = '\A/' . join( '/', @regex ) . '\z';
    return {
        template       => $template,
        regex          => qr/$source/,
        variables      => \@variables,
        ranks          => \@ranks,
        literal_length => $literal_length,
        literal        => !@variables,
        shape          => "/$shape",
        methods        => {},
    };
}

=head2 by_precedence($a, $b) = INTEGER

A function, for sort.  Below zero when the compiled template $a is tried
before $b, as DESCRIPTION says.

=cut

sub by_precedence {
    my ( $left, $right ) = @_;

    my @l = @{ $left->{ranks} };
    my @r = @{ $right->{ranks} };
    foreach my $i ( 0 .. List::Util::min( $#l, $#r ) ) {
        return $l[$i] <=> $r[$i] if $l[$i] != $r[$i];
    }
    return @l <=> @r || $right->{literal_length} <=> $left->{literal_length} || $left->{template} cmp $right->{template};
}

=head2 resolve_callback($what, $callback) = CODE

A function.  $callback when it is a CODE reference, and the sub that it names
when it is a fully qualified name.  It dies, and names $what, when there is no
callback or no such sub.

=cut

sub resolve_callback {
    my ( $what, $callback ) = @_;

    die "$what has no x-tpsgi-callback\n" unless defined $callback;
    return $callback                                                                  if ref $callback eq 'CODE';
    die "$what: x-tpsgi-callback is neither a CODE reference nor the name of a sub\n" if ref $callback;

    my $code = do {
        no strict 'refs';    # a sub that the router names
        defined &{$callback} ? \&{$callback} : undef;
    };
    die "$what: x-tpsgi-callback names $callback, which is not a defined sub\n" unless $code;
    return $code;
}

=head2 rules_for($schema, $method, $template) = HASHREF

What validate() checks of one operation beyond its schema: the names of its
query parameters, whether an undeclared key in the query is a 400, and the
media types of its request body.

=cut

sub rules_for {
    my ( $self, $schema, $method, $template ) = @_;

    my @parameters = @{ $schema->parameters_for_request( [ $method, $template ] ) };
    my %declared   = map  { $_->{name} => 1 } grep { $_->{in} eq 'query' } @parameters;
    my ($body)     = grep { $_->{in} eq 'body' } @parameters;

    return {
        query_names => \%declared,
        strict      => ( %declared || $body ) ? 1                                            : 0,
        body_types  => $body                  ? [ sort keys( %{ $body->{content} // {} } ) ] : undef,
    };
}

=head2 match($method, $path) = HASHREF

The route of a request, or undef when no template matches $path.

The route holds C<template>, C<method>, C<operation>, C<callback>, C<schema>
and C<path>, which maps each variable to its value.  The names in C<path> have
no C<+>.

When a template matches and none of the matching templates has an operation
for $method, the HASH holds C<status>, which is 405, and C<allow>, the methods
that they do have.  A HEAD request falls back to C<get>.

=cut

sub match {
    my ( $self, $method, $path ) = @_;

    $method = lc($method);
    my @tried;
    foreach my $matcher ( grep { defined } $self->{exact}{$path}, @{ $self->{templated} } ) {
        my @values = $matcher->{literal} ? () : $path =~ $matcher->{regex};
        next unless $matcher->{literal} || @values;
        push( @tried, $matcher );

        my $route = $matcher->{methods}{$method};
        $route //= $matcher->{methods}{get} if $method eq 'head';
        next unless $route;

        my %values;
        @values{ @{ $matcher->{variables} } } = @values;
        return { %$route, path => \%values };
    }
    return unless @tried;

    my %allow = map {
        map { uc($_) => 1 }
          keys( %{ $_->{methods} } )
    } @tried;
    $allow{HEAD} = 1 if $allow{GET};
    return { status => 405, allow => [ sort keys(%allow) ] };
}

=head2 validate($route, %request) = LIST

Check a request against the operation of the $route that match() returned.
%request holds C<query> and C<body>, each a HASH reference, C<content_type>,
and C<env>, the PSGI environment, from which the headers and cookies come.

It returns an empty list when the request is valid.  Otherwise it returns a
status and the reasons.  The status is 415 when the operation has a request
body and the media type of the request is not among its C<content>.  It is 400
when a parameter or the body does not match its schema, and when the query
holds a key that the operation does not declare.  The last rule holds only for
an operation that declares a query parameter or a request body.

The values of C<path>, C<query> and C<body> are coerced in place, so a parameter
of type integer arrives as a number.

=cut

sub validate {
    my ( $self, $route, %request ) = @_;

    my $query = $request{query} // {};
    my $body  = $request{body};
    my $env   = $request{env} // {};

    if ( $route->{body_types} && defined $body ) {
        my $type = $request{content_type} // '';
        return ( 415, "/body: '$type' is not one of @{ $route->{body_types} }" ) unless JSON::Validator::Util::negotiate_content_type( $route->{body_types}, $type );
    }

    if ( $route->{strict} ) {
        my %known      = ( %{ $route->{query_names} }, map { $_ => 1 } @reserved );
        my @undeclared = grep { !$known{$_} } sort keys(%$query);
        return ( 400, map { "/$_: the operation does not declare this parameter" } @undeclared ) if @undeclared;
    }

    my %cookies = map { split( m/=/, $_, 2 ) } split( m/ ; [ ]* /, $env->{HTTP_COOKIE} // '' );
    my %headers = map {
        my $name = lc( substr( $_, 5 ) );
        $name =~ tr/_/-/;
        ( $name => $env->{$_} )
    } grep { index( $_, 'HTTP_' ) == 0 } keys(%$env);

    my @seen;
    my $getter = sub {
        my ( $values, $fold ) = @_;
        return sub {
            my ($name) = @_;
            my $key    = $fold->($name);
            my $value  = { exists => exists $values->{$key}, value => $values->{$key} };
            push( @seen, [ $values, $key, $value ] );
            return $value;
        };
    };
    my $as_is = sub { return $_[0] };

    my @errors = $route->{schema}->validate_request(
        [ $route->{method}, $route->{template} ],
        {
            path   => $getter->( $route->{path}, sub { my $name = shift; $name =~ s/ [+] \z //; return $name } ),
            query  => $getter->( $query,         $as_is ),
            header => $getter->( \%headers,      sub { return lc( $_[0] ) } ),
            cookie => $getter->( \%cookies,      $as_is ),
            body   => sub {
                return { exists => defined $body, value => $body, content_type => $request{content_type} };
            },
        }
    );

    # validate_request() coerces its copy of each value, not the caller's.
    foreach my $seen (@seen) {
        my ( $values, $key, $value ) = @$seen;
        $values->{$key} = $value->{value} if $value->{exists};
    }

    return unless @errors;
    return ( 400, map { "$_" } @errors );
}

=head2 routes() = LIST

Each route as a HASH reference with C<template> and C<method>, in the order
match() tries them, for a caller that lists them.

=cut

sub routes {
    my ($self) = @_;
    my @matchers = ( map { $self->{exact}{$_} } sort keys( %{ $self->{exact} } ) );
    push( @matchers, @{ $self->{templated} } );
    return map {
        my $matcher = $_;
        map { $matcher->{methods}{$_} } grep { $matcher->{methods}{$_} } @methods
    } @matchers;
}

1;
