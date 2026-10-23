package TPSGI;

# ABSTRACT: Abstraction layer around starman to become a general purpose HTTP server & static renderer.

use 5.040;
use warnings FATAL => 'all';
use re '/aasx';

use Carp::Always;

use UUID();
use POSIX();
use Mojo::File;
use IO::Compress::Gzip;
use Plack::MIME;
use Time::HiRes qw{usleep gettimeofday tv_interval};

# For CGI features
use HTTP::Body;
use HTTP::Parser::XS qw{HEADERS_AS_HASHREF};
use CGI::Emulate::PSGI;

use Date::Format qw{strftime};
use List::Util();
use File::Find;
use Sys::Hostname();
use DateTime::Format::HTTP();

use URL::Encode();
use File::Touch;
use File::Path;

use File::Basename qw{dirname basename};
use Module::Runtime();
use Log::Dispatch;
use Log::Dispatch::Screen;
use Log::Dispatch::FileRotate;
use TPSGI::Startup;

# We have a DEBUG var which is plus ultra for extra sensitive stuff beyond just passing verbose
our $debug = $ENV{TPSGI_DEBUG};

#1MB chunks
our $CHUNK_SEP  = 'perlfsSep666YOLO42069';
our $CHUNK_SIZE = 1024000;

our %content_types = (
    text  => "text/plain",
    html  => "text/html",
    json  => "application/json",
    blob  => "application/octet-stream",
    xml   => "text/xml",
    xsl   => "text/xsl",
    css   => "text/css",
    rss   => "application/rss+xml",
    email => "multipart/related",
);

our %byct = reverse %content_types;

our %cache_control = (
    revalidate => "no-cache, max-age=0",
    nocache    => "no-store",
    static     => "public, max-age=604800, immutable",
);

#TODO consider integrating libfile
#Stuff that isn't in upstream finders
my %extra_types = (
    '.docx' => 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
);

my $ct = 'Content-type';

my $generic_handler;

=head2 request_id($regenerate) = STRING

The UUID of the request being answered, which every log line carries.  A true
$regenerate makes a new one, which app() does as each request comes in.

=cut

sub request_id {
    my ( $self, $regenerate ) = @_;
    return $self->{uuid} if $self->{uuid} && !$regenerate;
    $self->{uuid} = UUID::uuid();
    return $self->{uuid};
}

# The line each of the logging methods writes.
my sub log_line {
    my ( $self, $msg ) = @_;

    $msg //= "No message passed.  This is almost certainly a bug. ";

    #XXX Log lines must start as an ISO8601 date, anything else breaks fail2ban's beautiful mind
    my $tstamp = POSIX::strftime "%Y-%m-%dT%H:%M:%SZ", gmtime;
    my $uuid   = $self->request_id();

    my $udata = $self->{user} ? "[$self->{user}]" : "[nobody]";

    return "[Worker $$] {Request $uuid} $udata $tstamp : $self->{ip} $msg\n";
}

=head2 log() = Log::Dispatch

The process's Log::Dispatch, made by build_log() the first time it is asked
for.

=cut

sub log {    ## no critic (ProhibitBuiltinHomonyms) -- a method, which nothing calls as the builtin
    my $self = shift;

    state $log;
    return $log //= $self->build_log();
}

=head2 build_log() = Log::Dispatch

A new Log::Dispatch from the options: the rotated file at C<log_name>, the
screen, and each class that C<loggers> names, which is loaded by name.  log()
keeps the first one this makes.

=cut

sub build_log {
    my $self = shift;

    my $LOGNAME = $self->{log_name};
    my $LOGDIR  = $self->{log_dir};

    File::Path::make_path($LOGDIR) unless -d $LOGDIR;
    File::Touch::touch($LOGNAME)   unless -e $LOGNAME;

    my $LEVEL = $self->{verbose} ? 'debug' : 'info';

    # By default only log requests & warnings.
    # Otherwise emit debug messages.
    my $rotate = Log::Dispatch::FileRotate->new(
        name      => 'tcms',
        filename  => $LOGNAME,
        min_level => $LEVEL,
        'mode'    => 'append',
        size      => 10_485_760,    # 10 MiB
        max       => 6,
    );

    # Only send fatal events/errors to stdout
    my $screen = Log::Dispatch::Screen->new(
        name      => 'screen',
        min_level => $LEVEL,
    );

    my $log = Log::Dispatch->new();
    $log->add($rotate);
    $log->add($screen);

    # The first line is logged while new() is still loading the routers, so a
    # logger that an application ships beside its router is not loaded yet.
    foreach my $logger ( @{ $self->{loggers} } ) {
        $log->add( Module::Runtime::use_module($logger)->new( min_level => $LEVEL, log_dir => $LOGDIR ) );
    }

    $log->info( log_line( $self, "Opening Log $LOGNAME at $LEVEL level" ) );

    return $log;
}

=head2 DEBUG, INFO, NOTE, WARN, ERROR, CRIT, ALERT, EMERG, FATAL($message)

Log $message at that level, stamped with the time, the worker, the request and
the user.  FATAL logs at the emergency level and then dies with the line.

=cut

sub DEBUG {
    my ( $self, $msg ) = @_;
    return $self->log->debug( log_line( $self, $msg ) );
}

sub INFO {
    my ( $self, $msg ) = @_;
    return $self->log->info( log_line( $self, $msg ) );
}

sub NOTE {
    my ( $self, $msg ) = @_;
    return $self->log->notice( log_line( $self, $msg ) );
}

sub WARN {
    my ( $self, $msg ) = @_;
    return $self->log->warning( log_line( $self, $msg ) );
}

sub ERROR {
    my ( $self, $msg ) = @_;
    return $self->log->error( log_line( $self, $msg ) );
}

sub CRIT {
    my ( $self, $msg ) = @_;
    return $self->log->critical( log_line( $self, $msg ) );
}

sub ALERT {
    my ( $self, $msg ) = @_;
    return $self->log->alert( log_line( $self, $msg ) );
}

sub EMERG {
    my ( $self, $msg ) = @_;
    return $self->log->emergency( log_line( $self, $msg ) );
}

sub FATAL {
    my ( $self, $msg ) = @_;
    return $self->log->log_and_die( level => 'emergency', message => log_line( $self, $msg ) );
}

=head2 new(%options)

Load the routers and build the routing table.  It dies unless it runs as
C<user>, and C<http_user> and C<tpsgi_dir> are set.  get_config() returns the
options, and among them are:

    custom_log
    verbose
    routers
    loggers
    auth

=cut

sub new {
    my ( $class, %options ) = @_;

    # Refuse to run as wrong user, all config will be borked otherwise
    my $pname = getpwuid($>);
    die "Must run as configured user (got: $pname, want: $options{user})!" unless $pname eq ( $options{user} // '' );
    die "Must set http_user in options"                                    unless $options{http_user};
    die "Must set tpsgi_dir in options"                                    unless $options{tpsgi_dir};

    my $gid = getgrnam( $options{http_user} );
    die "No such user $options{http_user}" unless $gid;
    $options{gid} = $gid;

    my $self = bless( \%options, $class );
    $self->{ip} = '0.0.0.0';

    my @routes;
    my %aliases;

    # XXX TODO make these routes able to be fully qualified namespaces (::)!
    foreach my $route ( @{ $self->{routers} } ) {

        die "No such routing module $route" unless -e "$options{tpsgi_dir}/$route";

        # The router needs to exist and have nonzero numbers of routes.
        my ($package) = basename($route) =~ m/(\S+)[.]pm$/;

        # It also should be a top-level namespace, not somewhere deep down. KISS.
        my $libdir = dirname("$options{tpsgi_dir}/$route");
        push( @INC, $libdir );

        local $@;
        $self->DEBUG("require $options{tpsgi_dir}/$route");
        my $success = eval { require "$options{tpsgi_dir}/$route"; 1; };    ## no critic (RequireBarewordIncludes) -- a router is named by its file
        if ($success) {
            my ( $pkg_routes, $pkg_aliases, $pkg_watches ) = do {
                no strict 'refs';                                           # the router's own package variables, by name
                ( \@{"${package}::routes"}, \%{"${package}::aliases"}, \%{"${package}::watches"} );
            };

            for ( my $i = 0; $i < @$pkg_routes; $i += 2 ) {
                $self->DEBUG("Registered route $pkg_routes->[$i]");
            }
            push( @routes, @$pkg_routes );

            foreach my $al ( keys(%$pkg_aliases) ) {
                $self->DEBUG("aliased route $al to $pkg_aliases->{$al}");
            }
            @aliases{ keys(%$pkg_aliases) } = values(%$pkg_aliases);

            # Anything the router wants to watch, along with what to do when it changes.
            # Registration is idempotent, which matters because new() runs per request.
            foreach my $watched ( keys(%$pkg_watches) ) {
                my $spec = $pkg_watches->{$watched};

                # Copied rather than used directly, as we don't want to eat the router's own data.
                my %args = ref $spec eq 'HASH' ? %$spec : ( callback => $spec );
                $self->add_watch( $watched, delete $args{callback}, %args );
            }

            # First-come first-served error template overrides
            $generic_handler = $package->can('generic_route');
        }
        else {
            die "Could not load $route!\n$@\n";
        }
    }

    # Set the pattern used to discover the route if needed later.
    for ( my $i = 0; $i < scalar(@routes); $i += 2 ) {
        $routes[ $i + 1 ]{pattern} = $routes[$i];
    }

    $self->{indices} //= [];
    $self->{indices} = [ @{ $self->{indices} }, qw{index.html index.htm index.cgi} ];

    $self->{routes}    = \@routes;
    $self->{aliases}   = \%aliases;
    $self->{callbacks} = [];

    return $self;
}

=head2 indices() = ARRAYREF

The directory index files, in the order they are tried: the C<indices> option,
then F<index.html>, F<index.htm> and F<index.cgi>.

=cut

sub indices {
    my $self = shift;
    return $self->{indices};
}

=head2 routes() = ARRAYREF

The routing table: each route's pattern, then its definition, for every router
in the order they were loaded.

=cut

sub routes {
    my $self = shift;
    return $self->{routes};
}

=head2 serve($fullpath, $path, $start, $streaming, $ranges, $last_fetch, $deflate)

Serve a file, with options to stream and cache the output.

=cut

sub serve {    ## no critic (ProhibitManyArgs) -- routers call it with these, in this order
    my ( $self, $fullpath, $path, $start, $streaming, $ranges, $last_fetch, $deflate ) = @_;
    $last_fetch ||= 0;
    $deflate    ||= 0;

    my $mf  = Mojo::File->new($path);
    my $ext = '.' . $mf->extname();
    my $ft;
    if ($ext) {
        $ft = Plack::MIME->mime_type($ext) if $ext;
        $ft ||= $extra_types{$ext}         if exists $extra_types{$ext};
    }
    $ft ||= $content_types{text};

    my @headers = ( $ct => $ft );

    #TODO use static Cache-Control for everything but JS/CSS?
    push( @headers, 'Cache-control' => $cache_control{revalidate} );

    push( @headers, 'Accept-Ranges' => 'bytes' );

    $self->DEBUG("FETCH $path");
    my $mt         = ( stat($path) )[9];
    my $sz         = ( stat(_) )[7];
    my @gm         = gmtime($mt);
    my $now_string = strftime( "%a, %d %b %Y %H:%M:%S GMT", @gm );
    my $code       = $mt > $last_fetch ? 200 : 304;

    push( @headers, "Last-Modified" => $now_string );
    push( @headers, 'Vary'          => 'Accept-Encoding' );

    # The handle is the body of the response, so the server closes it.
    if ( open( my $fh, '<', $path ) ) {    ## no critic (RequireBriefOpen)
        return $self->serve_ranges( $fh, $ranges, size => $sz, headers => {@headers}, fullpath => $fullpath ) if @$ranges && $streaming;

        # Transfer-encoding: chunked
        return sub {
            my $responder = shift;
            push( @headers, 'Content-Length' => $sz );
            my $writer = $responder->( [ $code, \@headers ] );
            while ( $fh->read( my $buf, $CHUNK_SIZE ) ) {
                $writer->write($buf);
            }
            close($fh) or $self->WARN("Could not close $path: $!");
            $writer->close;
          }
          if $streaming && $sz > $CHUNK_SIZE;

        #Return data in the event the caller does not support deflate
        if ( !$deflate ) {
            push( @headers, "Content-Length" => $sz );

            # Append server-timing headers
            my $tot = tv_interval($start) * 1000;
            push( @headers, 'Server-Timing' => "file;dur=$tot" );

            return [ $code, \@headers, $fh ];
        }

        #Compress everything less than 1MB
        push( @headers, "Content-Encoding" => "gzip" );
        my $dfh;
        IO::Compress::Gzip::gzip( $fh => \$dfh );
        print $IO::Compress::Gzip::GzipError if $IO::Compress::Gzip::GzipError;
        push( @headers, "Content-Length" => length($dfh) );

        # Copy to the statics if it's not already there
        my $static_path = $path;
        $static_path =~ s{^/*www/}{};
        $static_path = "$self->{tpsgi_dir}/www/static/$static_path";

        my $target_dir = dirname($static_path);
        if ( !-d $target_dir ) {
            File::Path::make_path( $target_dir, { user => $<, group => $self->{gid}, chmod => 0o755 } ) or die "Could not make dir $target_dir";
        }

        # hardlink to save disk space.  One that is there already is this file.
        # TODO figure out cache invalidation, I guess check mtime/hash
        if ( link $path, $static_path ) {
            $self->INFO("Copying $path to $static_path");
        }
        elsif ( !$!{EEXIST} ) {
            $self->WARN("Could not link $path to $static_path: $!");
        }

        $self->INFO("GET 200 $fullpath");

        # Append server-timing headers
        my $tot = tv_interval($start) * 1000;
        push( @headers, 'Server-Timing' => "file;dur=$tot" );

        return [ $code, \@headers, [$dfh] ];
    }

    $self->INFO("GET 403 $fullpath");
    return [ 403, [ $ct => $content_types{text} ], ["Forbidden"] ];
}

=head2 serve_ranges($fh, $ranges, %args) = PSGI response

Answer a Range request from $fh with a 206, or a 416 when a range is outside
the file.  $ranges is what parse_ranges() returns, and %args is C<size>, the
size of the file, C<headers>, a HASH reference of the response headers so far,
and C<fullpath>, the URL for the log.  More than one range is answered as
multipart/byteranges.

=cut

sub serve_ranges {
    my ( $self, $fh, $ranges, %args ) = @_;
    my $sz       = $args{size};
    my %headers  = %{ $args{headers} };
    my $fullpath = $args{fullpath};

    # Set mode
    my $primary_ct   = "Content-Type: $headers{'Content-type'}";
    my $is_multipart = scalar(@$ranges) > 1;
    if ($is_multipart) {
        $headers{'Content-type'} = "multipart/byteranges; boundary=$CHUNK_SEP";
    }
    my $code = 206;

    my $fc = '';

    # Calculate the content-length up-front.  We have to fix unspecified lengths first, and reject bad requests.
    foreach my $range (@$ranges) {
        $range->[1] //= $sz - 1;
        if ( $range->[0] > $sz || $range->[0] < 0 || $range->[1] < 0 || $range->[0] > $range->[1] ) {
            $self->INFO("GET 416 $fullpath");
            return [ 416, [%headers], ["Requested range not satisfiable"] ];
        }
    }
    $headers{'Content-Length'} = List::Util::sum( map { $_->[1] + 1 - $_->[0] } @$ranges );

    #XXX Add the entity header lengths to the value - should hash-ify this to DRY
    if ($is_multipart) {
        foreach my $range (@$ranges) {
            $headers{'Content-Length'} += length("$fc--$CHUNK_SEP\n$primary_ct\nContent-Range: bytes $range->[0]-$range->[1]/$sz\n\n");
            $fc = "\n";
        }
        $headers{'Content-Length'} += length("\n--$CHUNK_SEP\--\n");
        $fc = '';
    }

    return sub {
        my $responder = shift;
        my $writer;

        foreach my $range (@$ranges) {
            $headers{'Content-Range'} = "bytes $range->[0]-$range->[1]/$sz" unless $is_multipart;
            $writer //= $responder->( [ $code, [%headers] ] );
            $writer->write("$fc--$CHUNK_SEP\n$primary_ct\nContent-Range: bytes $range->[0]-$range->[1]/$sz\n\n") if $is_multipart;
            $fc = "\n";

            my $len = List::Util::min( $sz, $range->[1] + 1 ) - $range->[0];

            $fh->seek( $range->[0], 0 );
            while ($len) {
                $fh->read( my $buf, List::Util::min( $len, $CHUNK_SIZE ) );
                $writer->write($buf);

                # Adjust for amount written
                $len = List::Util::max( $len - $CHUNK_SIZE, 0 );
            }
        }
        $fh->close();
        $writer->write("\n--$CHUNK_SEP--\n") if $is_multipart;
        $writer->close;
    };
}

# The page for an error code, which the router's generic_route() makes when it
# has one.
my sub generic {
    my ( $type, $code, $query ) = @_;

    if ($generic_handler) {
        my $rname = "/$code";
        my $title = $type;
        return $generic_handler->( $rname, $code, $title, $query );
    }

    $type .= Carp::longmess() if $debug;
    return [ $code, [ $ct => $content_types{html} ], ["$type"] ];
}

=head2 redirect, redirect_permanent, see_also

Redirects to the provided page.

=cut

sub redirect {
    my ( $self, $to ) = @_;
    $self->INFO("redirect: $to");
    return [ 302, [ "Location" => $to, "Content-Length" => 0 ], [''] ];
}

sub redirect_permanent {
    my ( $self, $to ) = @_;
    $self->INFO("permanent redirect: $to");
    return [ 301, [ "Location" => $to, "Content-Length" => 0 ], [''] ];
}

sub see_also {
    my ( $self, $to ) = @_;
    $self->INFO("see also: $to");
    return [ 303, [ "Location" => $to, "Content-Length" => 0 ], [''] ];
}

=head2 ok

Return a generic HTTP 200 OK

=cut

sub ok {
    my ( $self, $query, $body ) = @_;
    $self->INFO("$query->{method} 200 $query->{fullpath}");
    $body //= 'Ok';
    return generic( $body, 200, $query );
}

=head2 notfound, forbidden, badrequest, toolong, error, unavailable

If you need to return these HTTP errors, return these within a route:

    sub route {
        my ($self, $query) = @_;
        ...
        return $self->notfound($query);
    }

=cut

sub notfound {
    my ( $self, $query, $body ) = @_;
    $self->INFO("$query->{method} 404 $query->{fullpath}");
    $body //= 'Not Found';
    return generic( $body, 404, $query );
}

sub forbidden {
    my ( $self, $query, $body ) = @_;
    $self->INFO("$query->{method} 403 $query->{fullpath}");
    $body //= 'Forbidden';
    return generic( $body, 403, $query );
}

sub badrequest {
    my ( $self, $query, $body ) = @_;
    $self->INFO("$query->{method} 400 $query->{fullpath}");
    $body //= 'Bad Request';
    return generic( $body, 400, $query );
}

sub toolong {
    my ( $self, $query, $body ) = @_;
    $self->INFO("$query->{method} 419 $query->{fullpath}");
    $body //= 'URI too long';
    return generic( $body, 419, $query );
}

sub error {
    my ( $self, $query, $body ) = @_;
    my $method = $query->{method}   // "?";
    my $fp     = $query->{fullpath} // "?";
    $body //= 'Internal Server Error';
    $self->INFO("$method 500 $fp");
    return generic( $body, 500, $query );
}

sub unavailable {
    my ( $self, $query, $body ) = @_;
    $self->INFO("$query->{method} 503 $query->{fullpath}");
    $body //= 'Service Unavailable';
    return generic( $body, 503, $query );
}

my $cur_query = {};

=head2 app($env) = PSGI response

The PSGI application: respond() to the request, or answer it with error() when
that dies.

=cut

sub app {
    my ( $self, $env ) = @_;
    return eval { $self->respond($env) } || do {
        my $err = $@;
        $env->{'psgi.errors'}->print($err) if $env->{'psgi.errors'};

        # psgi.errors is the server's stderr, which a daemonized server sends
        # nowhere unless it was started with --error-log.  The log is the one
        # place that is always there, so the reason goes in it whole.
        $self->ERROR("Request failed: $err");

        # Redact the stack trace past line 1, it usually has things which should not be shown
        $cur_query->{message} = $err;
        $cur_query->{message} =~ s/\n.*//g if $cur_query->{message} && !$debug;

        return $self->error($cur_query);
    };
}

=head2 cannot_start($error, $env, %options) = ARRAYREF

What to answer with when new() died, so there is no object to answer with.
Usually a router that would not load: a missing module, a syntax error.

The error goes to psgi.errors, and to the log by way of a stand-in built from
the same options, so it lands in the same places a request's own errors do.  If
building the log is what failed -- a logger that will not load -- psgi.errors
is all there is, and the answer is still a 500 rather than a second exception.

The answer is a page of our own, not the router's error page: the router is
what failed.  With TPSGI_DEBUG set it carries the error itself, trace and all,
for the same reason the error pages add one; without, it says nothing a visitor
could use to map the installation.

The worker retires once it has answered, on a server that offers
psgix.harakiri, which Starman does.  A router that died while it compiled
leaves its file in %INC as a failure, and every later require of it in this
process says only "Attempt to reload ... aborted" -- so a load that failed
once, to a race or a lock, would otherwise fail for every request the worker
ever serves.  A fresh worker tries again from nothing.

=cut

sub cannot_start {
    my ( $error, $env, %options ) = @_;

    $env->{'psgi.errors'}->print($error) if ref $env eq 'HASH' && $env->{'psgi.errors'};

    # When the log will not build either, psgi.errors above is all there is.
    eval { bless( { %options, ip => '0.0.0.0' }, __PACKAGE__ )->ERROR("Could not start: $error"); 1 };    ## no critic (RequireCheckingReturnValueOfEval)

    $env->{'psgix.harakiri.commit'} = 1 if ref $env eq 'HASH' && $env->{'psgix.harakiri'};

    my $detail = '';
    if ($debug) {
        ( my $escaped = $error ) =~ s/([&<>"])/'&#' . ord($1) . ';'/ge;
        $detail = "<pre>$escaped</pre>";
    }

    my $page = "<!doctype html><html><head><meta charset=\"utf-8\"><title>Internal Server Error</title></head>" . "<body><h1>Internal Server Error</h1>$detail</body></html>";

    return [ 500, [ $ct => $content_types{html} ], [$page] ];
}

my %etags;

# A router's pattern means what the router wrote, so none of this file's
# default flags apply to it: /aa would make \w ASCII only, /x would drop its
# spaces, and /s would change what a dot matches.
my sub match_route {
    my ( $path, $pattern ) = @_;
    no re '/aasx';
    return $path =~ m/^$pattern$/;    ## no critic (RequireDefault RequireExtendedFormatting RequireDotMatchAnything)
}

=head2 respond($env) = PSGI response

Answer one request: from a route when one matches, by running a CGI when the
file under F<www/> is executable, and otherwise by serving the file.

=cut

sub respond {
    my ( $self, $env ) = @_;

    # Start the server timing clock
    my $start = [gettimeofday];
    $cur_query = {};

    $self->{filehandle} = $env->{'psgix.io'} // *STDOUT;
    $self->{input}      = $env->{'psgi.input'};

    # Setup the unique ID for the request
    $env->{REQUEST_ID} = $self->request_id(1);

    # Discard the path used in the log, it's too long and enough 4xx error code = ban
    return $self->toolong( { method => $env->{REQUEST_METHOD}, fullpath => '...' } ) if length( $env->{REQUEST_URI} ) > 2048;

    # Various stuff important for logging requests
    my $domain = $env->{HTTP_X_FORWARDED_HOST} || $env->{HTTP_HOST} // eval { Sys::Hostname::hostname() };
    my $path   = $env->{PATH_INFO}             || '/';

    # de-pooplicate the path
    $path =~ s{//}{/}g;

    my $port   = $env->{HTTP_X_FORWARDED_PORT} // $env->{HTTP_PORT};
    my $pport  = defined $port ? ":$port" : "";
    my $scheme = $env->{'psgi.url_scheme'} // 'http';
    my $method = $env->{REQUEST_METHOD};

    # It's important that we log what the user ACTUALLY requested rather than the rewritten path later on.
    my $fullpath = "$scheme://$domain$pport$path";

    # So we can log it for fail2ban
    my $ip = $env->{HTTP_X_FORWARDED_FOR} || $env->{REMOTE_ADDR};

    # set the referer & ua to go into DB logs, but not logs in general.
    # The referer/ua largely has no importance beyond being a proto bug report for log messages.
    my $referer = $env->{HTTP_REFERER};
    my $ua      = $env->{HTTP_UA};

    $cur_query = {
        route    => $path,
        fullpath => $path,
        method   => $method,
        ip       => $ip,
        ua       => $ua,
        referer  => $referer,
        tpsgi    => $self,
    };

    # Paths with .. in them are not refused here, because starman appears to
    # refuse them already.

    # Support aliased paths
    my $aliases = $self->{aliases};
    $path = $aliases->{$path} if exists $aliases->{$path};

    # Check eTags.  If we don't know about it, just assume it's good and lazily fill the cache
    # XXX yes, this allows cache poisoning...but only for logged in users!
    # This also needs to be IN DB so that we coordinate properly across forks
    if ( $env->{HTTP_IF_NONE_MATCH} ) {
        $self->INFO("$env->{REQUEST_METHOD} 304 $fullpath");
        return [ 304, [], [''] ] if $env->{HTTP_IF_NONE_MATCH} eq ( $etags{ $env->{REQUEST_URI} } || '' );
        $etags{ $env->{REQUEST_URI} } = $env->{HTTP_IF_NONE_MATCH} unless exists $etags{ $env->{REQUEST_URI} };
    }

    # TODO: Actually do something with the language passed to the renderer, HTTP_ACCEPT_LANGUAGE
    # TODO: Actually do something with the acceptable output formats in the renderer, HTTP_ACCEPT

    my $last_fetch = 0;
    if ( $env->{HTTP_IF_MODIFIED_SINCE} ) {
        $last_fetch = DateTime::Format::HTTP->parse_datetime( $env->{HTTP_IF_MODIFIED_SINCE} )->epoch();
    }

    # Figure out if we want compression or not
    my $alist = $env->{HTTP_ACCEPT_ENCODING} || '';
    $alist =~ s/\s//g;
    my @accept_encodings = split( /,/, $alist );
    my $deflate          = grep { 'gzip' eq $_ } @accept_encodings;

    # Set the IP of the request so we can fail2ban
    $self->{ip} = $env->{HTTP_X_FORWARDED_FOR} || $env->{REMOTE_ADDR} || $self->{ip};

    # Make sure this works further down the line
    $env->{REMOTE_ADDR} = $env->{HTTP_X_FORWARDED_FOR} if $env->{HTTP_X_FORWARDED_FOR};

    my $streaming = $env->{'psgi.streaming'};

    # If we have an actual route, just use it.
    my $r           = $self->routes;
    my $route_index = List::Util::first { ( $r->[$_] // '' ) eq $path } 0 .. scalar(@$r);

    my $route_actual;
    $route_actual = $r->[ $route_index + 1 ] if defined($route_index);

    # Might be a regexed route. Sort reversed so we try the longest routes first.
    if ( !$route_actual && @$r ) {
        my $matched = List::Util::first {

            # Here's where you want to use Regexp::Debugger in the context of call.pl to debug routes... EX:
            # perl ./call.pl GET /path/to/route
            match_route( $path, $r->[$_] );
        }
        0 .. scalar(@$r) - 1;
        $route_actual = $r->[ $matched + 1 ] if defined($matched);
    }

    if ($route_actual) {
        return $self->route(
            $route_actual, $env,
            fullpath   => $fullpath,
            path       => $path,
            start      => $start,
            last_fetch => $last_fetch,
            deflate    => $deflate,
            domain     => $domain,
            port       => $port,
        );
    }

    # Do a case insensitive match, because osx and windows
    my $file_possible = $self->mangle_filename("www/$path");
    my $file_actual;
    $file_actual = $file_possible if -e $file_possible && !-d _;

    # Dirindices
    if ( -d $file_possible ) {
        foreach my $index ( @{ $self->indices } ) {
            next if $file_actual;
            my $dirindex = $self->mangle_filename("www$path/$index");
            $dirindex =~ s{//}{/}g;
            $file_actual = $dirindex if -e $dirindex && !-d _;
        }
    }

    my $file_is_cgi = appears_executable($file_actual);
    return $self->cgi( $env, $fullpath, $file_actual, $last_fetch ) if $file_is_cgi;

    $self->INFO( "Attempting to serve $fullpath [" . ( $file_possible // "" ) . "]" );
    my @ranges = parse_ranges($env);
    return $self->serve( $fullpath, $file_actual, $start, $streaming, \@ranges, $last_fetch, $deflate ) if $file_actual;
    return $self->notfound($cur_query);
}

=head2 mangle_filename($path) = STRING

$path, lowercased on the systems whose filesystems ignore case.

=cut

sub mangle_filename {
    my ( $self, $path ) = @_;

    # XXX yes, you can have case sensitive OSX, but basically nobody enables that ever
    $path = lc($path) if List::Util::any { $^O eq $_ } qw{darwin MSWin32 dos};
    $self->DEBUG("Path mangled to $path");
    return $path;
}

=head2 parse_ranges($env) = LIST

The byte ranges of the request's Range header, as ARRAY references of start
and end.  An end that the header leaves out is undef.  If-Range without Range
asks for the whole file.

=cut

sub parse_ranges {
    my $env = shift;

    # Handle HTTP range/streaming requests
    my $range;
    $range = $env->{HTTP_RANGE} || "bytes=0-" if $env->{HTTP_RANGE} || $env->{HTTP_IF_RANGE};

    my @ranges;
    if ($range) {
        $range =~ s{bytes=}{}g;
        push(
            @ranges,
            map { [ split( /-/, $_ ) ]; } split( /,/, $range )
        );
    }
    return @ranges;
}

my @executable_extensions = qw{cgi sh exe pl php py};

=head2 appears_executable($path) = BOOL

Whether $path is a CGI to run rather than a file to serve: it is executable,
and it has no extension or one of C<cgi>, C<sh>, C<exe>, C<pl>, C<php> and C<py>.

=cut

sub appears_executable {
    my $subj = shift;

    # Definitely not executable if it does not exist!
    return 0 unless $subj;
    return 0 unless -x $subj;    ## no critic (ProhibitFiletest_rwxRWX) -- whether to run it, not whether we may
    my ($extension) = $subj =~ m/[.](\S+)$/;
    return 1 if !$extension;
    return 1 if List::Util::any { $extension eq $_ } @executable_extensions;
    return 0;
}

=head2 route($route, $env, %request) = PSGI response

Run the callback of $route that answers the request's content type, with the
query that extract_query() builds.  respond() calls it, with %request holding
C<fullpath>, C<path>, C<start>, C<last_fetch>, C<deflate>, C<domain> and
C<port>.

=cut

sub route {
    my ( $self, $route, $env, %request ) = @_;
    my ( $fullpath, $path, $start ) = @request{qw{fullpath path start}};

    $self->DEBUG( 'Executing route ' . $route->{pattern} );

    $route->{method} = $env->{REQUEST_METHOD} if $route->{method} eq '*';
    my $content_type = $env->{CONTENT_TYPE} || 'text/html';    # If not set, that's the assumption.
    return $self->badrequest($cur_query) unless List::Util::any { $_ eq $env->{REQUEST_METHOD} } grep { defined $_ } ( 'HEAD', $route->{method} );

    my $callback;
    if ( exists $route->{callbacks}{'*'} ) {
        $callback = $route->{callbacks}{'*'};
    }
    else {
        return $self->badrequest($cur_query) unless exists $route->{callbacks}{$content_type};
        $callback = $route->{callbacks}{$content_type};
    }

    my $streaming = $env->{'psgi.streaming'};

    # Build the query data for passing to a route.
    # GET, POST, URI captures, then explicit data overrides.
    my $query = {};

    # If we're running in CGI mode, leave everything as-is.
    $query = $self->extract_query( $path, $route, $env ) unless $route->{env};

    # We failed validation if $query isn't a hashref.
    return $query if ref $query eq 'ARRAY';

    # allow this stuff to survive down to the end of some routes
    $query->{last_fetched} = $request{last_fetch};
    $query->{deflate}      = $request{deflate};
    $query->{streaming}    = $streaming;
    my @ranges = parse_ranges($env);
    $query->{ranges} = \@ranges;
    $query->{start}  = $start;

    # Put things to tv_interval in here for Server-Timing
    $query->{fullpath}   = $fullpath;
    $query->{method}     = $route->{method};
    $query->{route}      = $path;
    $query->{cookies}    = $env->{HTTP_COOKIE};
    $query->{dnt}        = $env->{HTTP_DNT};
    $query->{nosellinfo} = $env->{HTTP_SEC_GPC};
    $query->{port}       = $request{port};
    $query->{scheme}     = $env->{'psgi.url_scheme'} // 'http';
    $query->{method}     = $env->{REQUEST_METHOD};
    $query->{lang}       = $env->{HTTP_ACCEPT_LANGUAGE};
    $query->{accept}     = $env->{HTTP_ACCEPT};
    $query->{has_query}  = !!$env->{QUERY_STRING};
    $query->{domain}     = $request{domain};
    $query->{dispatcher} = $route;
    $query->{ip}         = $cur_query->{ip};
    $query->{ua}         = $cur_query->{ua};
    $query->{referer}    = $cur_query->{referer};

    # This allows for better error handlers if we die in the route.
    $cur_query = $query;

    # Setup the CGI vars they expect IF requested
    local %ENV = ( %ENV, CGI::Emulate::PSGI->emulate_environment($env) ) if $route->{env};

    # Emulate mod_unique_id
    local $ENV{UNIQUE_ID} = UUID::uuid() if $route->{env};

    # Run any watch callbacks, and make this a truly 'dynamic' application if requested.
    $self->handle_changes();

    my $output = $callback->( $self, $query );

    # If it's streaming, just hand it off.
    # It's up to the caller to handle things like running post-close callbacks in this event.
    return $output if ref $output eq 'CODE';

    die "$fullpath returned no or malformed data!" unless ref $output eq 'ARRAY' && @$output == 3;

    my %headers = @{ $output->[1] };
    my $bytes   = $headers{'Content-Length'} // '?';
    $self->INFO("$env->{REQUEST_METHOD} $output->[0] $bytes $fullpath");

    # Append server-timing headers if they aren't present
    my $tot = tv_interval($start) * 1000;
    push( @{ $output->[1] }, 'Server-Timing' => "app;dur=$tot" ) unless List::Util::any { $_ eq 'Server-Timing' } @{ $output->[1] };

    # In the event that we have post-close callbacks, go ahead and run them.
    return $self->stream_raw_psgi( $output, $query ) if @{ $self->{callbacks} };

    return $output;
}

=head2 extract_query($path, $route, $env) = HASHREF

The query a route's callback is given: the query string, then the POST body,
then the route's captures and its C<data>, each over the last.  When the route
names C<parameters>, a parameter that fails its validator, or one it does not
name, gets a badrequest() instead.

=cut

sub extract_query {
    my ( $self, $path, $route, $env ) = @_;

    my $query;
    $query = URL::Encode::url_params_mixed( $env->{QUERY_STRING} ) if $env->{QUERY_STRING};

    #Actually parse the POSTDATA and dump it into the QUERY object if this is a POST
    if ( $env->{REQUEST_METHOD} eq 'POST' ) {

        my $body = HTTP::Body->new( $env->{CONTENT_TYPE}, $env->{CONTENT_LENGTH} );
        while ( $env->{'psgi.input'}->read( my $buf, $CHUNK_SIZE ) ) {
            $body->add($buf);
        }

        @$query{ keys( %{ $body->param } ) }  = values( %{ $body->param } );
        @$query{ keys( %{ $body->upload } ) } = values( %{ $body->upload } );
    }

    if ( ref $route->{captures} eq 'ARRAY' ) {
        my @captures = match_route( $path, $route->{pattern} );
        @$query{ @{ $route->{captures} } } = @captures;
    }

    if ( ref $route->{data} eq 'HASH' ) {
        @$query{ keys( %{ $route->{data} } ) } = values( %{ $route->{data} } );
    }

    # Now that we've parsed the query and know where we want to go,
    # we should (optionally) murder everything the route does not explicitly want, and validate what it does
    my $parameters = $route->{parameters};
    if ( ref $parameters eq 'HASH' && %$parameters ) {
        my @known_params = keys(%$parameters);
        for my $param (@known_params) {
            die "Invalid route definition for $path: parameter $param must correspond to a validation CODEREF." unless ref $parameters->{$param} eq 'CODE';

            # A missing parameter is not necessarily a problem.
            next unless $query->{$param};

            # But if we have it, and it's bad, nack it, so that scanners get fail2banned.
            $self->DEBUG("Rejected $path for bad query param $param");
            return $self->badrequest($query) unless $parameters->{$param}->( $query->{$param} );
        }

        # Without this logging will break.
        push( @known_params, qw{tpsgi ip ua user referer route dispatcher} );

        # Smack down passing of unnecessary fields; this catches bugs
        foreach my $field ( keys(%$query) ) {
            next if List::Util::any { $field eq $_ } @known_params;
            $self->WARN("Unexpected parameter $field passed");
            return $self->badrequest($query);
        }
    }

    return $query;
}

=head2 cgi($env, $fullpath, $file_actual, $last_fetch) = PSGI response

Run $file_actual as a CGI.  Read until we are done with headers, then pass off
the filehandle to PSGI for streaming.

=cut

# TODO support compression
sub cgi {
    my ( $self, $env, $fullpath, $file_actual, $last_fetch ) = @_;
    $self->INFO("Handoff $fullpath to $file_actual for cgi exec");

    # Setup the CGI vars they expect
    local %ENV = ( %ENV, CGI::Emulate::PSGI->emulate_environment($env) );

    # Running the CGI is the job.  The handle is read to its end in the stream below.
    my $pid = open( my $out, '-|', $file_actual ) or die "Could not run $file_actual: $!";    ## no critic (ProhibitPipeOpen RequireBriefOpen)
    my ( $code, undef, %headers ) = extract_headers( $out, $last_fetch );
    $code //= 500;
    return sub {
        my $responder = shift;

        my $writer = $responder->( [ $code, [%headers] ] );
        while ( $out->read( my $buf, $CHUNK_SIZE ) ) {
            $writer->write($buf);
        }
        $writer->close;

        # Wait on the CGI script to do whatever it's doing after closing stdout
        close($out) or $self->WARN("$file_actual exited with status $?");
        waitpid( $pid, 0 );
    };
}

=head2 stream_raw_cgi($cgi)

Run the perl file $cgi in this process, as a CGI: its STDIN is the request body,
and what it prints goes to the client.  The worker exits when it is done.

Use when you just have a .cgi file you want to run without pipe-open.
XXX this is extraordinarily unsafe, inefficient and kills workers.
XXX it also has an 'apache-ism' of just assigning the HTTP status line for you.
But sometimes you have to bite the bullet and do this to migrate stuff effectively.

=cut

sub stream_raw_cgi {
    my ( $self, $cgi ) = @_;

    # Discard STDIN in favor of the HTTP body.  Not localized, because this
    # process exits at the end of this sub.
    close(STDIN) or $self->DEBUG("STDIN was not open: $!");
    *STDIN = $self->{input};    ## no critic (RequireLocalizedPunctuationVars)

    # Similarly make 'print' do what CGIs expect
    my $fh = $self->{filehandle};
    select($fh);                ## no critic (ProhibitOneArgSelect)

    do($cgi);

    # We may or may not actually get here.
    close($fh) or $self->WARN("Could not close the response: $!") if $fh;
    exit 0;
}

=head2 stream_raw_psgi($response, $query)

Write the PSGI $response straight to the client's socket, close it, then run
the callbacks that add_post_close_callback() queued.  route() does this when
there are any.  The worker exits when it is done.

=cut

sub stream_raw_psgi {
    my ( $self, $response, $data ) = @_;

    my $time_to_here = tv_interval( $data->{start} );
    $self->DEBUG("Routing took $time_to_here s");
    my $post_routing = [gettimeofday];

    my $fh = $self->{filehandle};

    my $head = "HTTP/1.1 $response->[0]\n";

    # Emit the rest of the headers
    foreach ( my $i = 0; $i < @{ $response->[1] }; $i += 2 ) {
        my $header = $response->[1][$i];
        my $value  = $response->[1][ $i + 1 ];
        $head .= "$header: $value\n";
    }

    # Then the body
    print {$fh} "$head\n", $response->[2][0];

    close($fh) or $self->WARN("Could not close the response: $!");

    $self->DEBUG( "Response written in " . ( tv_interval($post_routing) ) . " s" );
    while ( my $callback = shift @{ $self->{callbacks} } ) {
        if ( ref $callback eq 'CODE' ) {
            my $post_start = [gettimeofday];
            local $@;
            eval { $callback->(); 1 } or $self->ERROR("Post-close callback encountered exception: $@");
            $self->DEBUG( "Post-close callback took " . ( tv_interval($post_start) ) . " s" );
        }
    }
    exit 0;
}

=head2 stream_raw_http($query, $last_fetch, $to_fork, $callback, $error_handler)

Answer with a 200 whose headers and body a forked child prints: $to_fork runs
in the child with the client's socket selected, and then $error_handler, when
there is one.  Once the child exits and the socket is closed, $callback runs.
The worker exits when it is done.

=cut

sub stream_raw_http {    ## no critic (ProhibitManyArgs) -- routers call it with these, in this order
    my ( $self, $data, $last_fetch, $to_fork, $callback, $error_handler ) = @_;

    my $time_to_here = tv_interval( $data->{start} );
    $self->DEBUG("Routing took $time_to_here s");
    my $post_routing = [gettimeofday];

    my $fh = $self->{filehandle};

    # The CGIs you are executing here SHOULD NOT emit a status line.
    # Most apache CGIs you find don't anyways, so this is usually not a big deal.
    # Then our server-timing header.
    print {$fh} "HTTP/1.1 200 OK\n", "Server-Timing: " . $self->build_server_timing($data) . "\n";

    # We *must* fork because we can't rely on the child to close stdout.
    $fh->autoflush(1);
    my $pid = fork() // die "Could not fork child";
    if ( $pid == 0 ) {

        # So that what the child prints goes to the client.
        select($fh);    ## no critic (ProhibitOneArgSelect)
        $self->DEBUG( "Forking child took" . ( tv_interval($post_routing) ) . " s" );
        local $@;
        eval { $to_fork->(); 1 } or $self->ERROR("Raw HTTTP streaming encountered exception: $@");
        if ( ref $error_handler eq 'CODE' ) {
            local $@;
            eval { $error_handler->(); 1 } or $self->ERROR("HTTP streaming error handler encountered exception: $@");
        }
        exit 0;
    }

    waitpid( $pid, 0 );
    close($fh) or $self->WARN("Could not close the response: $!");

    $self->DEBUG( "Response written in " . ( tv_interval($post_routing) ) . " s" );
    if ( ref $callback eq 'CODE' ) {
        my $post_start = [gettimeofday];
        local $@;
        eval { $callback->(); 1 } or $self->ERROR("Post-close callback encountered exception: $@");
        $self->DEBUG( "Post-close callback took " . ( tv_interval($post_start) ) . " s" );
    }
    exit 0;
}

=head2 extract_headers($fh, $last_fetch)

Extract the headers from a filehandle.  Set the 'Last Modified' header appropriately based on the output of `stat` on the filehandle.

Returns a code and parsed headers hash.  Code will be 304 if the file hasn't changed since $last_fetch, otherwise will be the code in the parsed headers.

=cut

sub extract_headers {
    my ( $fh, $last_fetch, $is_ref ) = @_;
    my $headers = '';

    # NOTE: this is relying on while advancing the file pointer
    while (<$fh>) {
        last if $_ eq "\n";
        $headers .= $_;
    }

    #XXX still a toctou
    my $offset = $fh->tell();
    my ( undef, undef, $status, undef, $headers_parsed ) = HTTP::Parser::XS::parse_http_response( "$headers\n", HEADERS_AS_HASHREF );

    my $code = $status // 200;
    $headers_parsed //= {};
    if ( !$is_ref ) {
        my $mt         = ( stat($fh) )[9];
        my @gm         = gmtime($mt);
        my $now_string = strftime( "%a, %d %b %Y %H:%M:%S GMT", @gm );
        $code = $mt > $last_fetch ? $status : 304;
        $headers_parsed->{"Last-Modified"} = $now_string;
    }

    return ( $code, $offset, %$headers_parsed );
}

=head2 static($fullpath, $path, $start, $streaming, $last_fetch) = PSGI response

Answer with the static render of $path that save_render() made, headers and
all, or forbidden() when there is none.

=cut

sub static {    ## no critic (ProhibitManyArgs) -- routers call it with these, in this order
    my ( $self, $fullpath, $path, $start, $streaming, $last_fetch ) = @_;

    $self->DEBUG("Rendering static for $path");

    # XXX because of psgi I can't just vomit the file directly
    # The handle is the body of the response, so the server closes it.
    if ( open( my $fh, '<', "statics/$path" ) ) {    ## no critic (RequireBriefOpen)
        my ( $code, $offset, $headers_parsed ) = ( 200, undef, {} );
        ( $code, $offset, %$headers_parsed ) = extract_headers( $fh, $last_fetch );

        # Append server-timing headers
        my $tot = tv_interval($start) * 1000;
        $headers_parsed->{'Server-Timing'} = "static;dur=$tot";

        #XXX uwsgi just opens the file *again* when we already have a filehandle if it has a path.
        # starman by comparison doesn't violate the principle of least astonishment here.
        # This is probably a performance optimization, but makes the kind of micromanagement I need to do inconvenient.
        # As such, we will just return a stream.
        $self->INFO("GET 200 $headers_parsed->{'Content-Length'} $fullpath");

        return sub {
            my $responder = shift;

            #push(@headers, 'Content-Length' => $sz);
            my $writer = $responder->( [ $code, [%$headers_parsed] ] );
            while ( $fh->read( my $buf, $CHUNK_SIZE ) ) {
                $writer->write($buf);
            }
            close($fh) or $self->WARN("Could not close statics/$path: $!");
            $writer->close;
          }
          if $streaming;

        return [ $code, [%$headers_parsed], $fh ];
    }
    return $self->forbidden( $self->{current_query} );
}

=head2 get_config() = HASH

TPSGI::Startup::get_config(): F<~/.tpsgi.ini>, over the defaults.

=cut

sub get_config { return TPSGI::Startup::get_config() }

=head2 checkpoint($query, $name)

Mark the time as $name, for the Server-Timing header that
build_server_timing() makes.

=cut

sub checkpoint {
    my ( $self, $data, $name ) = @_;
    $data->{checkpoints} //= [ [ start => $data->{start} ] ];
    push( @{ $data->{checkpoints} }, [ $name => [gettimeofday] ] );
    return;
}

=head2 build_server_timing($query) = STRING

A Server-Timing header value: how long each checkpoint() took after the one
before it, and the total since the request started.

=cut

sub build_server_timing {
    my ( $self, $data ) = @_;
    my @st;
    my $last_interval;
    foreach my $checkpoint ( @{ $data->{checkpoints} } ) {
        if ($last_interval) {
            my $dur = tv_interval( $last_interval, $checkpoint->[1] ) * 1000;
            push( @st, "$checkpoint->[0];dur=$dur" );
        }
        $last_interval = $checkpoint->[1];
    }
    my $tot = tv_interval( $data->{start} ) * 1000;
    push( @st, "tot;dur=$tot" );

    delete $data->{checkpoints};

    return join( ', ', @st );
}

=head2 add_post_close_callback()

Add a thing to do after closing stdout; useful for housekeeping that doesn't need to hold up pageload.

=cut

sub add_post_close_callback {
    my ( $self, $cb ) = @_;
    push( @{ $self->{callbacks} }, $cb );
    return;
}

=head2 signal_restart_parent()

Instruct tPSGI to reload after closing stdout.

=cut

sub signal_restart_parent {
    my ($self) = @_;
    $self->add_post_close_callback( sub { kill 'HUP', getppid } );
    return;
}

=head2 save_render($path, $extension, $body)

Save a static render of the page.
Good to queue after closing stdout.

Passed file extension slapped on the end of the path.
You can then serve them as statics with an appropriately done try_files block in nginx.

=cut

# Remove one static render.
my sub invalidate_file {
    my ( $self, $file ) = @_;
    $self->INFO("Remove static render $file");
    return unlink $file;
}

# fixup matrix
my %fixup = (
    text => 'txt',
    blob => 'bin',
);

sub save_render {
    my ( $self, $path, $extension, $body ) = @_;

    return unless $path && $extension;

    # If this is an index, let's make it so
    if ( $path =~ m{/$} ) {
        $path = $path . 'index';
    }

    # Fixup the extension if needed.
    $extension = $fixup{$extension} if exists $fixup{$extension};

    my $path_fixed = $path;
    $path_fixed =~ s/[.]\Q$extension\E$//;
    $path_fixed = "$path_fixed.$extension";

    my $path2file = "$self->{tpsgi_dir}/www/static/" . dirname($path_fixed);
    if ( !-d $path2file ) {
        File::Path::make_path( $path2file, { user => $<, group => $self->{gid}, chmod => 0o755 } ) or die "Could not create directory $path2file";
    }
    my $file = "$self->{tpsgi_dir}/www/static/$path_fixed";

    my $verb = -e $file ? 'Overwrite' : 'Write';
    $self->INFO("$verb $path as static/$path_fixed");

    open( my $fh, '>', $file ) or die "Could not open $file for writing";
    print {$fh} $body;
    close($fh) or die "Could not write $file: $!";
    chmod( 0755, $file );
    chown( $<, $self->{gid}, $file );
    return;
}

=head2 invalidate_render($path, $extension)

Remove an existing static render of a path.

=cut

sub invalidate_render {
    my ( $self, $path, $extension ) = @_;

    return unless $path && $extension;

    # Fixup the extension if needed.
    $extension = $fixup{$extension} if exists $fixup{$extension};

    my $path_fixed = $path;
    $path_fixed =~ s/[.]\Q$extension\E$//;
    $path_fixed = "$path_fixed.$extension";

    my $file = "$self->{tpsgi_dir}/www/static/$path_fixed";

    return unless -e $file;
    return invalidate_file( $self, $file );
}

=head2 invalidate_renders($extension)

Remove all existing static renders with the provided extension.
Useful when it's not easy to figure out what to re-render due to including templates in other templates, etc.

=cut

sub invalidate_renders {
    my ( $self, $extension ) = @_;
    File::Find::find(
        {
            wanted => sub {
                my $object = $_;
                invalidate_file( $self, $object ) if ( !-d $object && $object =~ m/[.]\Q$extension\E$/ );
            },
            no_chdir => 1,
            bydepth  => 1,
        },
        "$self->{tpsgi_dir}/www/static/"
    );
    return;
}

=head2 watch_for_changes(@dirs)

TPSGI::Startup::watch_for_changes(), which watches the .pm files under @dirs for
autoreload.  A function, not a method.

=cut

sub watch_for_changes {
    my (@dirs) = @_;
    return TPSGI::Startup::watch_for_changes(@dirs);
}

=head2 add_watch($path, $callback, %options)

Add an arbitrary file or directory to the inotify watchlist, along with a
callback to run when it changes.  Returns the inotify watch descriptor.

The callback is invoked as:

    $callback->( $tpsgi, $change );

...where $change is a HASH reference describing what happened:

    path    => full path of the thing which changed
    watched => the path the watch was registered against
    events  => ARRAY reference of event names, e.g. [ 'MODIFY' ]
    name    => entry within a watched directory, if the watch was on a directory
    wd      => inotify watch descriptor
    mask    => raw inotify event mask

Which makes the common case - blowing away a static render because the thing it
was generated from changed - look like:

    $tpsgi->add_watch( "data/posts.json", sub {
        my ( $tpsgi, $change ) = @_;
        $tpsgi->invalidate_renders('html');
    });

%options are passed through to TPSGI::Startup::add_watch, so you may also pass
'events' (defaults to CREATE, MODIFY, DELETE and MOVE) and 'key' (an explicit
dedupe key for the callback).

Some caveats worth knowing about:

=over

=item * Watches live in the inotify instance tarbaby sets up before forking, and
are therefore shared by every worker.  Whichever worker notices a change first
consumes it for all of them, so register the same callbacks in every worker
(declare them in your router module, which every worker loads) and make sure
they're safe to run in any worker.

=item * Changes are only noticed when a request comes in, since nothing is
sitting in a select loop over the inotify FD.  Renders are invalidated promptly
in practice, but not instantly.

=item * Watching a directory rather than a single file is more robust, as
watching a file which is later replaced wholesale (the usual write-tempfile-then-
rename dance) only survives because we re-establish the watch afterwards.  If
the file is deleted and not immediately recreated, the watch is gone for good.

=back

=cut

sub add_watch {
    my ( $self, $path, $callback, %options ) = @_;

    my $existing = TPSGI::Startup::is_watched($path);

    # A watch we can't establish (the usual cause being a path which isn't there yet)
    # shouldn't be fatal to the request which happened to be the one registering it.
    local $@;
    my $wd = eval {
        TPSGI::Startup::add_watch(
            %options,
            path     => $path,
            callback => $callback,
        );
    };
    if ( !defined $wd ) {
        my $why = $@;
        $why =~ s/\n.*// if $why;
        $self->WARN("Could not watch $path for changes: $why");
        return undef;
    }

    $self->DEBUG("Watching $path for changes") unless $existing;

    return $wd;
}

=head2 remove_watch($path)

Drop a path, and any callbacks registered against it, from the watchlist.

=cut

sub remove_watch {
    my ( $self, $path ) = @_;
    return TPSGI::Startup::remove_watch($path);
}

=head2 handle_changes

Drain the inotify queue, running the callbacks registered for whatever changed,
and restart tPSGI if any of the relevant libdir files changed (assuming
autoreload is on).  Powers both the autorestart feature and app-registered
watches.

=cut

sub handle_changes {
    my $self = shift;

    my @changes = TPSGI::Startup::pending_changes();
    return 0 unless @changes;

    my $had_changes = 0;
    my @rewatch;

    foreach my $change (@changes) {
        my $watch = $change->{watch};

        # A watch descriptor we know nothing about belongs to a worker which registered
        # watches we didn't.  All we can sensibly do with those is the old behavior.
        if ( !$watch ) {
            $had_changes++ if $change->{path} =~ m/[.]pm$/;
            next;
        }

        $had_changes++ if $watch->{restart} && $change->{path} =~ m/[.]pm$/;

        foreach my $cb ( @{ $watch->{callbacks} } ) {
            local $@;
            my $ok = eval { $cb->{code}->( $self, $change ); 1 };
            $self->WARN("Watch callback for $change->{path} died: $@") unless $ok;
        }

        # The kernel drops watches on files which get replaced or deleted, so put them back.
        push( @rewatch, $change->{wd} ) if List::Util::any { $_ eq 'IGNORED' } @{ $change->{events} };
    }

    TPSGI::Startup::rewatch($_) foreach @rewatch;

    return 0 unless $had_changes && $self->{autoreload};

    # We don't have to clean up the wds, that is handled in the destructor for Inotify
    $self->INFO("Relevant Change in libdirs detected, reloading\n");
    $self->signal_restart_parent();
    return 0;
}

=head2 restart_if_changes

Deprecated alias for handle_changes().

=cut

sub restart_if_changes { goto &handle_changes }

1;

__END__

=head1 SYNOPSIS

A router module, which C<routers> in F<~/.tpsgi.ini> names:

    package My::Routes;

    our @routes = (
        '/hello' => {
            method    => 'GET',
            callbacks => { 'text/html' => \&hello },
        },
    );

    sub hello {
        my ( $tpsgi, $query ) = @_;
        return [ 200, [ 'Content-Type' => 'text/html' ], ['Hello world'] ];
    }

=head1 DESCRIPTION

Start it with the Starman options you want, from the directory of the
application, with tarbaby on the PATH:

    tpsgi ... [starman args]

A PSGI server built to migrate old mod_perl/apache stacks onto psgi, and that powers tCMS.

Will execute any executable file (chmod +x) in www/ as CGI, and otherwise host any static file therein.

The idea here is as a bridge between old and new which allows you to modernize at your own pace, gradually turning CGIs into routes.

The other idea is that we don't want to add any extra abstraction if we don't have to, while gently guiding into better practices.
Shops used to having full control over the HTTP response should continue to do so, rather than being locked into one framework or another.
This allows them to continue doing whatever funky thing they have been doing, like COMET, et cetera.
The best way to do that is to expect raw PSGI to be output.

=head1 CONFIGURATION

Obeys ~/.tpsgi.ini -- this is what will control all the custom aspects mentioned below:

    verbose     : Whether to print all log messages or not
    custom_log  : Custom location for default (rotated) log
    routers     : Router module(s), separate with comma.  Relative to TPSGI install dir.
    indices     : Dirindex files.  In addition to index.html, index.htm, index.cgi
    loggers     : Logger module(s), separate with comma.  Each is a Log::Dispatch::Output class.  tPSGI loads it by name, so it can live beside a router
    auth        : Authentication module
    domain      : Domain name of the application, used by things like service files
    basedir     : Directory you want to chdir into on startup. Relative to TPSGI install dir.  Default '.'
    user        : Who to run as
    http_user   : Who's proxying this application (used for statics)
    autoreload  : Whether or not to automatically reload the application when library files change. Default 0.

You can run bin/tpsgi-config to get any config value needed by scripts.

We wrap starman with a custom script, C<bin/tarbaby> that implements Plack::Loader::Reload far less dangerously.
It only reloads the code relevant to tPSGI and your application itself.
All the CPAN deps should be updated out-of-band and the service manually restarted, as this is far more fraught.

=head1 CUSTOM ROUTING

All passed routing modules will be required, and combined to form a routing table so you have an analogue to rewrite rules.

Routing Modules look like so:

    our @routes = (
        '/foo/(\w+)/save' => {
            method    => 'GET',
            callbacks => { # Run these subroutines to execute the appropriate handler given the content-type.  Expects normal PSGI output.
                'text/html'        => \&render,
                'application/json' => \&dump,
            },
            noindex   => 0, # Explicitly exclude this in robots.txt
            nomap     => 0, # Don't put this in the sitemap
            acls      => ['admin'], # Route requires both authentication by auth handler and the auth'd user to have the provided ACLs.
            data      => { baz => 'throb' }, # Arbitrary data to inject into the GET/POST data hashref
            captures  => ['name','parameter'], # Name parameters of the capture groups in the route key.  Suppose we want /foo/don/keys here.
            static    => 1, # Whether we can save a static render of this
            invalidates => ['/foo/(\w+)'], # Static renders which are invalidated by this route returning a successful response code.
        },
        ...
    );

Note that this is an array, as we want this to preserve order. Fat commas are used to hint that this is in fact a tuple.

Router callbacks are passed the TPSGI object and the raw query, which means you can do:

    sub route {
        my ($self, $query) = @_;
        $self->INFO("whatever");
        $self->ERROR("eeee");
        $self->DEBUG("blah");

        # Either from the GET or POST data, POST is preferred when both are present.
        my $param = $query->{param};

        my %headers = ...;

        return [200, \%headers, ["Hello world"]]
    }

=head1 WATCHING FILES FOR CHANGES

tPSGI already watches your library directories with inotify so that it can reload itself when your
code changes.  Your application can put arbitrary files and directories onto that same watchlist,
along with a callback to run when they change.  The usual reason to want this is throwing away a
static render because the thing it was generated from changed underneath it.

Routing modules declare these the same way they declare routes:

    our %watches = (
        # A bare coderef is the common case: run this when the path changes.
        'data/posts.json' => sub {
            my ($tpsgi, $change) = @_;
            $tpsgi->invalidate_renders('html');
        },

        # Or spell it out if you want to be picky about which events you care about.
        'www/assets' => {
            callback => \&asset_changed,
            events   => [qw{CREATE MOVE}],
        },
    );

...or register them at runtime with C<< $tpsgi->add_watch($path, $callback, %options) >>, and drop them
again with C<< $tpsgi->remove_watch($path) >>.

Callbacks are passed the TPSGI object and a hashref describing what happened:

    sub asset_changed {
        my ($tpsgi, $change) = @_;

        $change->{path};    # full path of the thing which changed
        $change->{watched}; # the path the watch was registered against
        $change->{events};  # arrayref of event names, e.g. ['MODIFY']

        $tpsgi->invalidate_render($change->{path}, 'html');
    }

A few things worth knowing:

=over

=item *

Watches are shared by every worker, so whichever worker notices a change first consumes it for all
of them.  Declare your watches in your routing module (which every worker loads) rather than from
inside a single route, and make the callbacks safe to run in any worker.

=item *

Nothing sits in a select loop over the inotify descriptor, so changes are noticed when the next
request comes in.  Prompt, but not instant.

=item *

Watching the containing directory is more robust than watching a single file.  Watches on files
which get replaced wholesale (write a tempfile, rename over the target) are re-established
afterwards, but a file which is deleted and not recreated takes its watch with it.

=back

=head1 CUSTOM AUTHENTICATION HANDLING

The (optional) Authentication handler can be passed, and look like so:

    package Auth::Handler;

    # Is user who they say they are
    sub authenticate {
        my (%auth_payload) = @_;
        ...
        return ($session_cookie);
    }

    # is the user authorized to do $thing
    sub authorized {
        my ($user, $priv) = @_;
        ...
        return 1 || 0;
    }

    # Available ACLs
    sub acls {
        ...
        return %acls;
    }

    # Dump acls for user
    sub acls_for_user {
        my $user = shift;
        ...
        return %acls;
    }

    # What is the user for this session token
    sub user_for_session {
        my $session = shift;
        ...
        return $user;
    }

In the event that auth or route handlers are found, these events will be noted in the startup log.

=head1 LOGGING

By default we have two log handlers...which you can augment with your own, based on Log::Dispatch.

The first default is to print ERROR and worse to the STDOUT of the PSGI server.
The other is to emit INFO or better to logs/tpsgi.log

Pass your own dispatch subclasses and watch it go whir.

=head1 SERVICE CONFIGURATION

Proper operation of this as a production service requires some things:

=over

=item 1.

You have a user which has this repository as their home directory.

=item 2.

You run the shell script, tpsgi.sh in service/ to run this as a service.

=item 3.

You set the username and the domain name of the service in .tpsgi.ini

=item 4.

You set your PATH appropriately to pick up on things like custom perls in a .bashrc

=item 5.

You set the group of your reverse proxy application in .tpsgi.ini (the http_user variable)

=back

run service/tpsgi.sh as root and you should be set supposing the above is true.

In general the operation is like so:

=over

=item 1.

nginx (or whatever) looks for a sock file owned $USER:$WEB_GROUP, and reverse proxies to this

=item 2.

tpsgi is actively listening on this sock file.

=back

Generally you'll just run bin/build_service and then systemctl start $domain.
It's configured to start as root, then drop privs thanks to Net::Server's capabilities inherited in starman.

=head2 Secrets the application needs

An application often needs a key or a password that has no business living in
its own checkout, where it would go into every backup alongside whatever it
protects.  bin/build_service makes one and puts it in systemd's credential
store; the unit imports it and service/tpsgi.sh hands it on.

You do not have to do anything for this.  build_service writes
C</etc/credstore.encrypted/tpsgi-vault> if it is not there already, encrypted
with C<systemd-creds --with-key=auto>: sealed to the TPM when the machine has a
usable one, and to the host key when it does not.  It says which you got, since
that is the difference between a stolen disk being useless and a stolen disk
being a stolen key.  An existing key is left alone.

systemd decrypts it into a ramdisk at C</run/credentials/$service> that only this
service can read.  Nothing breaks if it is not there: C<ImportCredential=> is
quiet about a credential that does not exist, so an installation whose
application wants no secrets starts normally.

The workers are chrooted into the application directory and that ramdisk is
outside it, so service/tpsgi.sh reads the credential before the chroot happens
and exports it -- C<tpsgi-vault> becomes C<TPSGI_VAULT_KEY>.  An application taking
one is expected to read it out of its environment as it starts and delete it
there and then, so that nothing it forks afterwards inherits it.

It is named for tPSGI rather than for whatever is being served, because this is
tPSGI's unit and one service is one application in one directory.

The key is not backed up and cannot be recovered.  That is deliberate: it lives
and dies with the machine, so that it is never sitting in the same backup as the
data it protects.  Rebuilding the host means whatever was sealed under it is
gone and gets stored again.

=cut
