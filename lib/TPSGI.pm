package TPSGI;

# Abstract: Abstraction layer around starman to become a general purpose HTTP server & static renderer.

use strict;
use warnings;

use feature qw{state};

use FindBin;

use Carp::Always;

use UUID();
use POSIX();
use Mojo::File;
use IO::Compress::Gzip;
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
use File::Copy;
use Cwd            qw{abs_path};

use File::Basename qw{dirname basename};
use Log::Dispatch;
use Log::Dispatch::Screen;
use Log::Dispatch::FileRotate;
use Config::Simple;
use TPSGI::Startup;

# We have a DEBUG var which is plus ultra for extra sensitive stuff beyond just passing verbose
my $debug = $ENV{TPSGI_DEBUG};

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

#memoize
my $rq;

my $generic_handler;

sub request_id {
    my ( $self, $regenerate ) = @_;
    return $self->{uuid} if $self->{uuid} && !$regenerate;
    $self->{uuid} = UUID::uuid();
    return $self->{uuid};
}

sub log {
    my $self = shift;

    state $log;
    return $log if $log;

    my $LOGNAME= $self->{log_name};
    my $LOGDIR = $self->{log_dir};

    File::Path::make_path($LOGDIR) unless -d $LOGDIR;
    File::Touch::touch($LOGNAME)   unless -f $LOGNAME;

    my $LEVEL = $self->{verbose} ? 'debug' : 'info';

    # By default only log requests & warnings.
    # Otherwise emit debug messages.
    my $rotate = Log::Dispatch::FileRotate->new(
        name      => 'tcms',
        filename  => $LOGNAME,
        min_level => $LEVEL,
        'mode'    => 'append',
        size      => 10 * 1024 * 1024,
        max       => 6,
    );

    # Only send fatal events/errors to stdout
    my $screen = Log::Dispatch::Screen->new(
        name      => 'screen',
        min_level => $LEVEL,
    );

    $log = Log::Dispatch->new();
    $log->add($rotate);
    $log->add($screen);
    foreach my $logger ( @{ $self->{loggers} } ) {
        $log->add( $logger->new( min_level => $LEVEL, log_dir => $LOGDIR ) );
    }

    $log->info( $self->_log("Opening Log $LOGNAME at $LEVEL level") );

    return $log;
}

sub _log {
    my ( $self, $msg ) = @_;

    $msg //= "No message passed.  This is almost certainly a bug. ";

    #XXX Log lines must start as an ISO8601 date, anything else breaks fail2ban's beautiful mind
    my $tstamp = POSIX::strftime "%Y-%m-%dT%H:%M:%SZ", gmtime;
    my $uuid   = $self->request_id();

    my $udata = $self->{user} ? "[$self->{user}]" : "[nobody]";

    return "[Worker $$] {Request $uuid} $udata $tstamp : $self->{ip} $msg\n";
}

# Logger short cuts
sub DEBUG {
    my $self = shift;
    $self->log->debug( $self->_log(shift) );
}

sub INFO {
    my $self = shift;
    $self->log->info( $self->_log(shift) );
}

sub NOTE {
    my $self = shift;
    $self->log->notice( $self->_log(shift) );
}

sub WARN {
    my $self = shift;
    $self->log->warning( $self->_log(shift) );
}

sub ERROR {
    my $self = shift;
    $self->log->error( $self->_log(shift) );
}

sub CRIT {
    my $self = shift;
    $self->log->critical( $self->_log(shift) );
}

sub ALERT {
    my $self = shift;
    $self->log->alert( $self->_log(shift) );
}

sub EMERG {
    my $self = shift;
    $self->log->emergency( $self->_log(shift) );
}

sub FATAL {
    my $self = shift;
    $self->log->log_and_die( level => 'emergency', message => $self->_log(shift) );
}

=head1 new(%options)

Options are:

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
    no strict 'refs';
    foreach my $route ( @{ $self->{routers} } ) {

        die "No such routing module $route" unless -f "$options{tpsgi_dir}/$route";

        # The router needs to exist and have nonzero numbers of routes.
        my ($package) = basename($route) =~ m/(\S+)\.pm$/;
        my $r         = "$package\:\:routes";
        my $a         = "$package\:\:aliases";

        # It also should be a top-level namespace, not somewhere deep down. KISS.
        my $libdir = dirname("$options{tpsgi_dir}/$route");
        push( @INC, $libdir );

        local $@;
        $self->DEBUG("require $options{tpsgi_dir}/$route");
        my $success = eval { require "$options{tpsgi_dir}/$route"; 1; };
        if ($success) {
            my $pkg_routes = *$r{ARRAY};
            for ( my $i = 0; $i < @$pkg_routes; $i += 2 ) {
                $self->DEBUG("Registered route $pkg_routes->[$i]");
            }
            push( @routes, @$pkg_routes );

            my $pkg_aliases = *$a{HASH};
            foreach my $al ( keys(%$pkg_aliases) ) {
                $self->DEBUG("aliased route $al to $pkg_aliases->{$al}");
            }
            @aliases{ keys(%$pkg_aliases) } = values(%$pkg_aliases);

            # First-come first-served error template overrides
            $generic_handler = "$package\:\:generic_route";
            $generic_handler = undef unless exists &{$generic_handler};
        }
        else {
            die "Could not load $route!\n$@\n";
        }
    }
    use strict 'refs';

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

sub indices {
    my $self = shift;
    return $self->{indices};
}

sub routes {
    my $self = shift;
    return $self->{routes};
}

=head2 serve

Serve a file, with options to stream and cache the output.

=cut

sub serve {
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

    if ( open( my $fh, '<', $path ) ) {
        return $self->_range( $fullpath, $fh, $ranges, $sz, @headers ) if @$ranges && $streaming;

        # Transfer-encoding: chunked
        return sub {
            my $responder = shift;
            push( @headers, 'Content-Length' => $sz );
            my $writer = $responder->( [ $code, \@headers ] );
            while ( $fh->read( my $buf, $CHUNK_SIZE ) ) {
                $writer->write($buf);
            }
            close $fh;
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
        $static_path =~ s|^[/]*www/||;
        $static_path = "$self->{tpsgi_dir}/www/static/$static_path";
        if ( !-f $static_path ) {

            my $target_dir = dirname($static_path);
            $self->INFO("Copying $path to $static_path");

            if ( !-d $target_dir ) {
                File::Path::make_path( $target_dir, { user => $<, group => $self->{gid}, chmod => 0755 } ) or die "Could not make dir $target_dir";
            }
            # hardlink to save disk space
            link $path, $static_path;

            # TODO figure out cache invalidation, I guess check mtime/hash
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

sub _range {
    my ( $self, $fullpath, $fh, $ranges, $sz, %headers ) = @_;

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
        $self->INFO("GET 416 $fullpath");
        return [ 416, [%headers], ["Requested range not satisfiable"] ] if $range->[0] > $sz || $range->[0] < 0 || $range->[1] < 0 || $range->[0] > $range->[1];
    }
    $headers{'Content-Length'} = List::Util::sum( map { my $arr = $_; $arr->[1] + 1, -$arr->[0] } @$ranges );

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

sub _generic {
    my ( $type, $code, $query ) = @_;

    if ($generic_handler) {
        my $rname = "/$code";
        my $title = $type;
        no strict 'refs';
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
    return _generic( $body, 200, $query );
}

=head2 notfound, forbidden, badrequest, toolong, error

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
    return _generic( $body, 404, $query );
}

sub forbidden {
    my ( $self, $query, $body ) = @_;
    $self->INFO("$query->{method} 403 $query->{fullpath}");
    $body //= 'Forbidden';
    return _generic( $body, 403, $query );
}

sub badrequest {
    my ( $self, $query, $body ) = @_;
    $self->INFO("$query->{method} 400 $query->{fullpath}");
    $body //= 'Bad Request';
    return _generic( $body, 400, $query );
}

sub toolong {
    my ( $self, $query, $body ) = @_;
    $self->INFO("$query->{method} 419 $query->{fullpath}");
    $body //= 'URI too long';
    return _generic( $body, 419, $query );
}

sub error {
    my ( $self, $query, $body ) = @_;
    my $method = $query->{method}   // "?";
    my $fp     = $query->{fullpath} // "?";
    $body //= 'Internal Server Error';
    $self->INFO("$method 500 $fp");
    return _generic( $body, 500, $query );
}

sub unavailable {
    my ( $self, $query, $body ) = @_;
    $self->INFO("$query->{method} 503 $query->{fullpath}");
    $body //= 'Service Unavailable';
    return _generic( $body, 503, $query );
}

my $cur_query = {};

sub app {
    my $self = shift;
    return eval { _app( $self, @_ ) } || do {
        my $env = shift;
        $env->{'psgi.errors'}->print($@) if $env->{'psgi.errors'};

        # Redact the stack trace past line 1, it usually has things which should not be shown
        $cur_query->{message} = $@;
        $cur_query->{message} =~ s/\n.*//g if $cur_query->{message} && !$debug;

        return $self->error($cur_query);
    };
}

my %etags;

sub _app {
    my $self = shift;

    # Start the server timing clock
    my $start = [gettimeofday];
    $cur_query = {};

    my $env = shift;
    $self->{filehandle} = $env->{'psgix.io'} // *STDOUT;
    $self->{input} = $env->{'psgi.input'};

    # Setup the unique ID for the request
    $env->{REQUEST_ID} = $self->request_id(1);

    # Discard the path used in the log, it's too long and enough 4xx error code = ban
    return $self->toolong( { method => $env->{REQUEST_METHOD}, fullpath => '...' } ) if length( $env->{REQUEST_URI} ) > 2048;

    # Various stuff important for logging requests
    my $domain = $env->{HTTP_X_FORWARDED_HOST} || $env->{HTTP_HOST} // eval { Sys::Hostname::hostname() };
    my $path   = $env->{PATH_INFO} || '/';

    # de-pooplicate the path
    $path =~ s|//|/|g;

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

    # Disallow any paths that are naughty - this appears to be done by starman automatically.
    #if ( index($path, '..') != -1 ) {
    #   return $self->forbidden($cur_query);
    #}

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

    # TODO: Actually do something with the language passed to the renderer
    my $lang = $env->{HTTP_ACCEPT_LANGUAGE};

    #TODO: Actually do something with the acceptable output formats in the renderer
    my $accept = $env->{HTTP_ACCEPT};

    my $last_fetch = 0;
    if ( $env->{HTTP_IF_MODIFIED_SINCE} ) {
        $last_fetch = DateTime::Format::HTTP->parse_datetime( $env->{HTTP_IF_MODIFIED_SINCE} )->epoch();
    }

    # Figure out if we want compression or not
    my $alist = $env->{HTTP_ACCEPT_ENCODING} || '';
    $alist =~ s/\s//g;
    my @accept_encodings;
    @accept_encodings = split( /,/, $alist );
    my $deflate = grep { 'gzip' eq $_ } @accept_encodings;

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
            #print $r->[$_]."\n";
            $path =~ m/^$r->[$_]$/;
        }
        0 .. scalar(@$r) - 1;
        $route_actual = $r->[ $matched + 1 ] if defined($matched);
    }

    return $self->route( $route_actual, $env, $fullpath, $path, $start, $last_fetch, $deflate, $domain, $port ) if $route_actual;

    # Do a case insensitive match, because osx and windows
    my $file_possible = $self->mangle_filename("www/$path");
    my $file_actual   = $file_possible if -f $file_possible;

    # Dirindices
    if ( -d $file_possible ) {
        foreach my $index ( @{ $self->indices } ) {
            next if $file_actual;
            my $dirindex = $self->mangle_filename("www$path/$index");
            $dirindex =~ s|//|/|g;
            $file_actual = $dirindex if -f $dirindex;
        }
    }

    my $file_is_cgi = appears_executable($file_actual);
    return $self->cgi( $env, $fullpath, $file_actual, $last_fetch, $deflate ) if $file_is_cgi;

    $self->INFO( "Attempting to serve $fullpath [" . ( $file_possible // "" ) . "]" );
    my @ranges = parse_ranges($env);
    return $self->serve( $fullpath, $file_actual, $start, $streaming, \@ranges, $last_fetch, $deflate ) if $file_actual;
    return $self->notfound($cur_query);
}

sub mangle_filename {
    my ( $self, $path ) = @_;

    # XXX yes, you can have case sensitive OSX, but basically nobody enables that ever
    $path = lc($path) if List::Util::any { $^O eq $_ } qw{darwin MSWin32 dos};
    $self->DEBUG("Path mangled to $path");
    return $path;
}

sub parse_ranges {
    my $env = shift;

    # Handle HTTP range/streaming requests
    my $range = $env->{HTTP_RANGE} || "bytes=0-" if $env->{HTTP_RANGE} || $env->{HTTP_IF_RANGE};

    my @ranges;
    if ($range) {
        $range =~ s/bytes=//g;
        push(
            @ranges,
            map { [ split( /-/, $_ ) ]; } split( /,/, $range )
        );
    }
    return @ranges;
}

my @executable_extensions = qw{cgi sh exe pl php py};

sub appears_executable {
    my $subj = shift;

    # Definitely not executable if it does not exist!
    return 0 unless $subj;
    return 0 unless -x $subj;
    my ($extension) = $subj =~ m/\.(\S+)$/;
    return 1 if !$extension;
    return 1 if grep { $extension eq $_ } @executable_extensions;
    return 0;
}

# Handle actual routes
sub route {
    my ( $self, $route, $env, $fullpath, $path, $start, $last_fetch, $deflate, $domain, $port ) = @_;

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
    $query->{last_fetched} = $last_fetch;
    $query->{deflate}      = $deflate;
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
    $query->{port}       = $port;
    $query->{scheme}     = $env->{'psgi.url_scheme'} // 'http';
    $query->{method}     = $env->{REQUEST_METHOD};
    $query->{lang}       = $env->{HTTP_ACCEPT_LANGUAGE};
    $query->{accept}     = $env->{HTTP_ACCEPT};
    $query->{has_query}  = !!$env->{QUERY_STRING};
    $query->{domain}     = $domain;
    $query->{dispatcher} = $route;
    $query->{ip}         = $cur_query->{ip};
    $query->{ua}         = $cur_query->{ua};
    $query->{referer}    = $cur_query->{referer};

    # This allows for better error handlers if we die in the route.
    $cur_query = $query;

    # Setup the CGI vars they expect IF requested
    local %ENV = ( %ENV, CGI::Emulate::PSGI->emulate_environment($env) ) if $route->{env};
    # Emulate mod_unique_id
    $ENV{UNIQUE_ID} = UUID::uuid() if $route->{env};

    # Make this a truly 'dynamic' application if requested.
    $self->restart_if_changes() if $self->{autoreload};

    {
        my $output = $callback->( $self, $query );

        # If it's streaming, just hand it off.
        # It's up to the caller to handle things like running post-close callbacks in this event.
        return $output if ref $output eq 'CODE';

        die "$fullpath returned no or malformed data!" unless ref $output eq 'ARRAY' && @$output == 3;

        my $pport   = defined $query->{port} ? ":$query->{port}" : "";
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
}

sub extract_query {
    my ( $self, $path, $route, $env ) = @_;

    my $query = URL::Encode::url_params_mixed( $env->{QUERY_STRING} ) if $env->{QUERY_STRING};

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
        my @captures = $path =~ m/^$route->{pattern}$/;
        @$query{ @{ $route->{captures} } } = @captures;
    }

    if ( ref $route->{data} eq 'HASH' ) {
        @$query{ keys( %{ $route->{data} } ) } = values( %{ $route->{data} } );
    }

    # Now that we've parsed the query and know where we want to go,
    # we should (optionally) murder everything the route does not explicitly want, and validate what it does
    my $parameters = $route->{parameters};
    if (ref $parameters eq 'HASH' && %$parameters) {
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
        push(@known_params, qw{tpsgi ip ua user referer route dispatcher});

        # Smack down passing of unnecessary fields; this catches bugs
        foreach my $field ( keys(%$query) ) {
            next if List::Util::any { $field eq $_ } @known_params;
            $self->WARN("Unexpected parameter $field passed");
            return $self->badrequest($query);
        }
    }

    return $query;
}

# Read until we are done with headers, then pass off the filehandle to PSGI for streaming.
# TODO support compression
sub cgi {
    my ( $self, $env, $fullpath, $file_actual, $last_fetch, $deflate ) = @_;
    $self->INFO("Handoff $fullpath to $file_actual for cgi exec");

    # Setup the CGI vars they expect
    local %ENV = ( %ENV, CGI::Emulate::PSGI->emulate_environment($env) );

    # Use the two-element list form so Perl exec()s the script directly
    # instead of passing it through /bin/sh, preventing shell injection via
    # filenames that contain shell metacharacters.
    my $pid = open( my $out, '-|', $file_actual, basename($file_actual) );
    die "Could not fork CGI $file_actual: $!" unless defined $pid;
    my ( $code, $offset, %headers ) = extract_headers( $out, $last_fetch );
    $code //= 500;
    return sub {
        my $responder = shift;

        my $writer = $responder->( [ $code, [%headers] ] );
        while ( $out->read( my $buf, $CHUNK_SIZE ) ) {
            $writer->write($buf);
        }
        $writer->close;

        # Wait on the CGI script to do whatever it's doing after closing stdout
        close $out;
        waitpid( $pid, 0 );
    };
}

# Use when you just have a .cgi file you want to run without pipe-open
# XXX this is extraordinarily unsafe, inefficient and kills workers.
# XXX it also has an 'apache-ism' of just assigning the HTTP status line for you.
# But sometimes you have to bite the bullet and do this to migrate stuff effectively.
sub stream_raw_cgi {
    my ($self, $cgi) = @_;

    # Discard STDIN in favor of the HTTP body
    close(STDIN);
    *STDIN = $self->{input};

    # Similarly make 'print' do what CGIs expect
    my $fh = $self->{filehandle};
    select $fh;

    do($cgi);
    # We may or may not actually get here.
    close($fh) if $fh;
    exit 0;
}

# Used primarily when we have post-close callbacks
sub stream_raw_psgi {
    my ( $self, $response, $data ) = @_;

    my $time_to_here = tv_interval( $data->{start} );
    $self->DEBUG("Routing took $time_to_here s");
    my $post_routing = [gettimeofday];

    my $fh = $self->{filehandle};

    print $fh "HTTP/1.1 $response->[0]\n";

    # Emit the rest of the headers
    foreach ( my $i = 0; $i < @{ $response->[1] }; $i += 2 ) {
        my $header = $response->[1][$i];
        my $value  = $response->[1][ $i + 1 ];
        print $fh "$header: $value\n";
    }
    print $fh "\n";

    # Emit the body
    print $fh $response->[2][0];

    close($fh);

    $self->DEBUG( "Response written in " . ( tv_interval($post_routing) ) . " s" );
    while ( my $callback = shift @{ $self->{callbacks} } ) {
        if ( ref $callback eq 'CODE' ) {
            my $post_start = [gettimeofday];
            local $@;
            eval { $callback->() };
            $self->ERROR("Post-close callback encountered exception: $@") if $@;
            $self->DEBUG( "Post-close callback took " . ( tv_interval($post_start) ) . " s" );
        }
    }
    exit 0;
}

sub stream_raw_http {
    my ( $self, $data, $last_fetch, $to_fork, $callback, $error_handler ) = @_;

    my $time_to_here = tv_interval( $data->{start} );
    $self->DEBUG("Routing took $time_to_here s");
    my $post_routing = [gettimeofday];

    my $fh = $self->{filehandle};

    # The CGIs you are executing here SHOULD NOT emit a status line.
    # Most apache CGIs you find don't anyways, so this is usually not a big deal.
    print $fh "HTTP/1.1 200 OK\n";

    # Emit our server-timing header.
    print $fh "Server-Timing: " . $self->build_server_timing($data) . "\n";    #app;dur=".($time_to_here*1000)."\n";

    # We *must* fork because we can't rely on the child to close stdout.
    my $pid = _fork(
        sub {
            $self->DEBUG( "Forking child took" . ( tv_interval($post_routing) ) . " s" );
            local $@;
            eval { $to_fork->() };
            $self->ERROR("Raw HTTTP streaming encountered exception: $@") if $@;
            if ( ref $error_handler eq 'CODE' ) {
                local $@;
                eval { $error_handler->() };
                $self->ERROR("HTTP streaming error handler encountered exception: $@") if $@;
            }
        },
        $fh
    );

    waitpid( $pid, 0 );
    close($fh);

    $self->DEBUG( "Response written in " . ( tv_interval($post_routing) ) . " s" );
    if ( ref $callback eq 'CODE' ) {
        my $post_start = [gettimeofday];
        local $@;
        eval { $callback->() };
        $self->ERROR("Post-close callback encountered exception: $@") if $@;
        $self->DEBUG( "Post-close callback took " . ( tv_interval($post_start) ) . " s" );
    }
    exit 0;
}

sub _fork {
    my ( $callback, $fh ) = @_;
    select $fh;
    $| = 1;
    my $pid = fork();
    die "Could not fork child" unless defined $pid;
    if ( $pid == 0 ) {
        $callback->();
        exit 0;
    }
    select STDOUT;
    return $pid;
}

=head2 extract_headers($fh, $last_fetch)

Extract the headers from a filehandle.  Set the 'Last Modified' header appropriately based on the output of `stat` on the filehandle.

Returns a code and parsed headers hash.  Code will be 304 if the file hasn't changed since $last_fetch, otherwise will be the code in the parsed headers.

=cut

sub extract_headers {
    my ( $fh, $last_fetch, $is_ref ) = @_;
    my $headers = '';

    # NOTE: this is relying on while advancing the file pointer
    # Accept both LF ("\n") and CRLF ("\r\n") as blank-line terminators,
    # per HTTP/1.1 which mandates CRLF but real-world CGIs often emit LF only.
    while (<$fh>) {
        last if $_ =~ /^\r?\n$/;
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
        $code = $mt > $last_fetch ? ($status // 200) : 304;
        $headers_parsed->{"Last-Modified"} = $now_string;
    }

    return ( $code, $offset, %$headers_parsed );
}

sub static {
    my ( $self, $fullpath, $path, $start, $streaming, $last_fetch ) = @_;

    $self->DEBUG("Rendering static for $path");

    # XXX because of psgi I can't just vomit the file directly
    if ( open( my $fh, '<', "statics/$path" ) ) {
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
            close $fh;
            $writer->close;
          }
          if $streaming;

        return [ $code, [%$headers_parsed], $fh ];
    }
    return $self->forbidden( $self->{current_query} );
}

sub get_config { return TPSGI::Startup::get_config(@_) }

# Convenience method to keep track of server-timing
sub checkpoint {
    my ( $self, $data, $name ) = @_;
    $data->{checkpoints} //= [ [ start => $data->{start} ] ];
    push( @{ $data->{checkpoints} }, [ $name => [gettimeofday] ] );
}

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
}

=head2 signal_restart_parent()

Instruct tPSGI to reload after closing stdout.

=cut

sub signal_restart_parent {
    my ($self) = @_;
    $self->add_post_close_callback( \&_restart_parent );
}

# Instruct tPSGI to reload.
sub _restart_parent  {
    my $parent = getppid;
    kill 'HUP', $parent;
}

=head2 save_render($path, $extension, $body)

Save a static render of the page.
Good to queue after closing stdout.

Passed file extension slapped on the end of the path.
You can then serve them as statics with an appropriately done try_files block in nginx.

=cut

# fixup matrix
my %fixup = (
    text => 'txt',
    blob => 'bin',
);

sub save_render {
    my ( $self, $path, $extension, $body ) = @_;

    return unless $path && $extension;

    # If this is an index, let's make it so
    if ($path =~ m|/$|) {
        $path = $path.'index';
    }

    # Fixup the extension if needed.
    $extension = $fixup{$extension} if exists $fixup{$extension};

    my $path_fixed = $path;
    $path_fixed =~ s/\.\Q$extension\E$//;
    $path_fixed = "$path_fixed.$extension";

    my $path2file = "$self->{tpsgi_dir}/www/static/" . dirname($path_fixed);
    if ( !-d $path2file ) {
        File::Path::make_path( $path2file, { user => $<, group => $self->{gid}, chmod => 0755 } ) or die "Could not create directory $path2file";
    }
    my $file = "$self->{tpsgi_dir}/www/static/$path_fixed";

    my $verb = -f $file ? 'Overwrite' : 'Write';
    $self->INFO("$verb $path as static/$path_fixed");

    open( my $fh, '>', $file ) or die "Could not open $file for writing";
    print $fh $body;
    close $fh;
    chmod( 0755, $file );
    chown( $<, $self->{gid}, $file );
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
    $path_fixed =~ s/\.\Q$extension\E$//;
    $path_fixed = "$path_fixed.$extension";

    my $file = "$self->{tpsgi_dir}/www/static/$path_fixed";

    return unless -f $file;
    $self->_invalidate($file);
}

sub _invalidate {
    my ($self, $file) = @_;
    $self->INFO("Delete $file");
    unlink "$file";
}

=head2 invalidate_renders($extension)

Remove all existing static renders with the provided extension.
Useful when it's not easy to figure out what to re-render due to including templates in other templates, etc.

=cut

sub invalidate_renders {
    my ($self, $extension) = @_;
    File::Find::find( {
        wanted => sub {
            my $object = $_;
            $self->_invalidate($object) if (-f $object && $object =~ m/\.\Q$extension\E$/);
        },
        no_chdir => 1,
        bydepth => 1,
    },
    "$self->{tpsgi_dir}/www/static/");
}

sub watch_for_changes { return TPSGI::Startup::watch_for_changes(@_) }

=head2 restart_if_changes

Restart tPSGI if any of the relevant libdir files change.
Powers the autorestart feature.

=cut

sub restart_if_changes {
    my $self = shift;

    my @result = $TPSGI::Startup::inotify->read();
    my $had_changes = 0;

    foreach my $res (@result) {
        if ( $res->{name} =~ m/\.pm$/ ) {
            $had_changes++;
            last;
        }
    }
    return 0 unless $had_changes;

    # We don't have to clean up the wds, that is handled in the destructor for Inotify
    $self->INFO("Relevant Change in libdirs detected, reloading\n");
    $self->signal_restart_parent();
    return 0;
}

1;
