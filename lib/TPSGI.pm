package TPSGI;

# Abstract: Abstraction layer around starman to become a general purpose HTTP server

use strict;
use warnings;

use feature qw{state};

use Carp::Always;

use POSIX();
use Mojo::File;
use Plack::MIME;
use IO::Compress::Gzip;
use Time::HiRes qw{tv_interval};

# For CGI features
use HTTP::Parser::XS qw{HEADERS_AS_HASHREF};
use CGI::Emulate::PSGI;

use Date::Format qw{strftime};
use List::Util();
use File::Find;
use Sys::Hostname();
use Plack::MIME  ();
use DateTime::Format::HTTP();
use Time::HiRes      qw{gettimeofday tv_interval};

use File::Touch;
use File::Path;
use Cwd qw{abs_path};
use File::Basename qw{dirname basename};
use Log::Dispatch;
use Log::Dispatch::Screen;
use Log::Dispatch::FileRotate;

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

my $ct      = 'Content-type';
#memoize
my $rq;
my $cur_query = {};

sub log {
    my $self = shift;
    
    state $log;
    return $log if $log;

    my $LOGNAME = abs_path('.').'/log/tpsgi.log';
    $LOGNAME = $self->{custom_log} if $self->{custom_log};

    my $LOGDIR = dirname($LOGNAME);
    File::Path::make_path($LOGDIR) unless -d $LOGDIR;
    File::Touch::touch($LOGNAME) unless -f $LOGNAME;

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
    foreach my $logger (@{$self->{loggers}}) {
        $log->add($logger->new( min_level => $LEVEL, log_dir => $LOGDIR ));
    }

    $log->info( $self->_log("Opening Log $LOGNAME at $LEVEL level") );

    return $log;
}

sub _log {
    my ( $self, $msg ) = @_;

    $msg //= "No message passed.  This is almost certainly a bug. ";

    #XXX Log lines must start as an ISO8601 date, anything else breaks fail2ban's beautiful mind
    my $tstamp = POSIX::strftime "%Y-%m-%dT%H:%M:%SZ", gmtime;

    return "[Worker $$] $tstamp : $self->{ip} $msg\n";
}

# Logger short cuts
sub DEBUG {
    my $self = shift;
    $self->log->debug( $self->_log( shift ) );
}
sub INFO {
    my $self = shift;
    $self->log->info( $self->_log( shift ) );
}
sub NOTE {
    my $self = shift;
    $self->log->notice( $self->_log( shift ) );
}
sub WARN {
    my $self = shift;
    $self->log->warning( $self->_log( shift ) );
}
sub ERROR {
    my $self = shift;
    $self->log->error( $self->_log( shift ) );
}
sub CRIT {
    my $self = shift;
    $self->log->critical( $self->_log( shift ) );
}
sub ALERT {
    my $self = shift;
    $self->log->alert( $self->_log( shift ) );
}
sub EMERG {
    my $self = shift;
    $self->log->emergency( $self->_log( shift ) );
}
sub FATAL {
    my $self = shift;
    $self->log->log_and_die( level => 'emergency', message => $self->_log( shift ) );
}

=head1 new(%options)

Options are:

    custom_log
    verbose
    routers
    loggers
    authn

=cut

sub new {
    my ($class, %options) = @_;

    my %routes;

    no strict 'refs';
    foreach my $route (@{$options{routers}}) {
        # The router needs to exist and have nonzero numbers of routes.
        my ($package) = basename($route) =~ m/(\S+)\.pm$/;
        my $r = "$package\:\:routes";
        my $success = eval { require $route; 1; };
        if ($success) {
            my $pkg_routes = *$r{HASH};
            @routes{keys(%$pkg_routes)} = values(%$pkg_routes);
        } else {
            die "Could not load $route!";
        }
    }
    use strict 'refs';

    # Set the pattern used to discover the route if needed later.
    foreach my $route (keys(%routes)) {
        $routes{$route}{pattern} = $route;
    }

    $options{indices} //=[];
    $options{indices} = [@{$options{indices}},qw{index.html index.htm index.cgi}];

    $options{routes} = \%routes;
    $options{ip} = '0.0.0.0';
    return bless(\%options, $class);
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
        $writer->write("\n--$CHUNK_SEP\--\n") if $is_multipart;
        $writer->close;
    };
}

sub _generic {
    my ( $type, $code ) = @_;
    return [$code, [$ct => $content_types{html}], ["$type"]];
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
    my ($self, $query, $body) = @_;
    $self->INFO("$query->{method} 404 $query->{fullpath}");
    $body //= 'Not Found';
    return _generic( $body, 404 );
}

sub forbidden {
    my ($self, $query, $body) = @_;
    $self->INFO("$query->{method} 403 $query->{fullpath}");
    $body //= 'Forbidden';
    return _generic( 'Forbidden', 403 );
}

sub badrequest {
    my ($self, $query, $body) = @_;
    $self->INFO("$query->{method} 400 $query->{fullpath}");
    $body //= 'Bad Request';
    return _generic( $body, 400 );
}

sub toolong {
    my ($self, $query, $body) = @_;
    $self->INFO("$query->{method} 419 $query->{fullpath}");
    $body //= 'URI too long';
    return _generic( $body, 419 );
}

sub error {
    my ($self, $query, $body) = @_;
    my $method = $query->{method} // "?";
    my $fp     = $query->{fullpath} // "?";
    $body //= 'Internal Server Error';
    $self->INFO("$method 500 $fp");
    return _generic( $body, 500 );
}

sub unavailable {
    my ($self, $query, $body) = @_;
    $self->INFO("$query->{method} 503 $query->{fullpath}");
    $body //= 'Service Unavailable';
    return _generic( $body, 503 );
}

my %etags;
my $domain;
sub app {
    my $self = shift;
    # Start the server timing clock
    my $start = [gettimeofday];

    my $env = shift;

    # Discard the path used in the log, it's too long and enough 4xx error code = ban
    return $self->toolong({ method => $env->{REQUEST_METHOD}, fullpath => '...' }) if length( $env->{REQUEST_URI} ) > 2048;

    # Various stuff important for logging requests
    $domain //= eval { Sys::Hostname::hostname() } // $env->{HTTP_X_FORWARDED_HOST} || $env->{HTTP_HOST};
    my $path = $env->{PATH_INFO};
    my $port   = $env->{HTTP_X_FORWARDED_PORT} // $env->{HTTP_PORT};
    my $pport  = defined $port ? ":$port" : "";
    my $scheme = $env->{'psgi.url_scheme'} // 'http';
    my $method = $env->{REQUEST_METHOD};

    # It's important that we log what the user ACTUALLY requested rather than the rewritten path later on.
    my $fullpath = "$scheme://$domain$pport$path";

    # sigdie can now "do the right thing"
    $self->{cur_query} = { route => $path, fullpath => $path, method => $method };

    # Check eTags.  If we don't know about it, just assume it's good and lazily fill the cache
    # XXX yes, this allows cache poisoning...but only for logged in users!
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
    $self->{ip} = $env->{HTTP_X_FORWARDED_FOR} || $env->{REMOTE_ADDR};

    my $streaming = $env->{'psgi.streaming'};

    # If we have an actual route, just use it.
    my $r = $self->routes;
    my $route_actual = $r->{$path};
    # Might be a regexed route.
    if (!$route_actual) {
        my $matched = List::Util::first { exists $r->{$_}{pattern} && $path =~ m/^$r->{$_}{pattern}$/ } keys(%$r);
        $route_actual = $r->{$matched} if $matched;
    }

    return $self->route( $route_actual, $env, $fullpath, $path, $start, $last_fetch, $deflate ) if $route_actual;

    # Do a case insensitive match, because osx and windows
    my $file_possible = lc("www$path");
    my $file_actual = $file_possible if -f $file_possible;

    # Dirindices
    if (-d $file_possible) {
        foreach my $index ($self->indices) {
            next if $file_actual;
            my $dirindex = lc("www$path/$index");
            $dirindex =~ s|//|/|g;
            $file_actual = $dirindex if -f $dirindex;
        }
    }

    my $file_is_cgi = appears_executable($file_actual);
    return $self->cgi( $env, $fullpath, $file_actual, $last_fetch, $deflate) if $file_is_cgi;

    $self->INFO("Attempting to serve $fullpath [".($file_possible // "")."]");
    my @ranges = parse_ranges($env);
    return $self->serve( $fullpath, $file_actual, $start, $streaming, \@ranges, $last_fetch, $deflate ) if $file_actual;
    return $self->notfound($self->{cur_query});
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
            map {
                [ split( /-/, $_ ) ];
            } split( /,/, $range )
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
    my ($self, $route, $env, $fullpath, $path, $start, $last_fetch, $deflate ) = @_;

    my $content_type = $env->{CONTENT_TYPE};
    # It is the responsibility of each route to respond to HEAD requests correctly
    return $self->badrequest($self->{cur_query}) unless List::Util::any { $_ eq $env->{REQUEST_METHOD} } ('HEAD', $route->{method});
    
    my $callback;
    if (exists $route->{callbacks}{'*'}) {
        $callback = $route->{callbacks}{'*'};
    } else {
        return $self->badrequest($self->{cur_query}) unless exists $route->{callbacks}{$content_type};
        $callback = $route->{callbacks}{$content_type};
    }

    # Provide static renders if available.
    my $streaming = $env->{'psgi.streaming'};
    return $self->static( $fullpath, "$fullpath.z", $start, $streaming ) if -f "statics/$fullpath.z" && $deflate;
    return $self->static( $fullpath, $fullpath,     $start, $streaming ) if -f "statics/$fullpath";

    # Build the query data for passing to a route.
    # GET, POST, URI captures, then explicit data overrides.
    my $query = $self->extract_query($path, $route, $env);

    # allow this stuff to survive down to the end of some routes
    $query->{last_fetched} = $last_fetch;
    $query->{deflate}      = $deflate;
    $query->{streaming}    = $streaming;
    my @ranges = parse_ranges($env);
    $query->{ranges}       = \@ranges;
    $query->{start}        = $start;
    $query->{fullpath}     = $fullpath;
    $query->{method}       = $route->{method};

    # This allows for better error handlers if we die in the route.
    $self->{cur_query} = $query;

    # Setup the CGI vars they expect IF requested
    local %ENV = (%ENV, CGI::Emulate::PSGI->emulate_environment($env)) if $route->{env};

    {
        my $output = $callback->($self, $query);

        # If it's streaming, just hand it off
        return $output if ref $output eq 'CODE';

        die "$fullpath returned no or malformed data!" unless ref $output eq 'ARRAY' && @$output == 3;

        my $pport = defined $query->{port} ? ":$query->{port}" : "";
        my %headers = @{$output->[1]};
        my $bytes = $headers{'Content-Length'} // '?';
        $self->INFO("$env->{REQUEST_METHOD} $output->[0] $bytes $fullpath");

        # Append server-timing headers if they aren't present
        my $tot = tv_interval($start) * 1000;
        push( @{ $output->[1] }, 'Server-Timing' => "app;dur=$tot" ) unless List::Util::any { $_ eq 'Server-Timing' } @{ $output->[1] };
        return $output;
    }
}

sub extract_query {
    my ($self, $path, $route, $env) = @_;

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

    if (ref $route->{captures} eq 'ARRAY') {
       my @captures = $path =~ m/^$route->{pattern}$/;
       @$query{@{$route->{captures}}} = @captures;
    }

    if (ref $route->{data} eq 'HASH') {
        @$query{keys(%{$route->{data}})} = values(%{$route->{data}});
    }
    return $query;
}

# Read until we are done with headers, then pass off the filehandle to PSGI for streaming.
# TODO support compression
sub cgi {
    my ( $self, $env, $fullpath, $file_actual, $last_fetch, $deflate) = @_;
    $self->INFO("Handoff $fullpath to $file_actual for cgi exec");

    # Setup the CGI vars they expect
    local %ENV = (%ENV, CGI::Emulate::PSGI->emulate_environment($env));

    my $pid = open(my $out, '-|', "$file_actual");
    my ($code, %headers) = extract_headers($out, $last_fetch);
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
        waitpid($pid, 0);
    };
}

sub stream_raw_http {
    my ($self, $output, $last_fetch, $callback) = @_;

    open(my $out, '<', \$output) or die "I couldn't open a string as a filehandle, which can only happen if you don't compile perl with PerlIO";
    my ($code, %headers) = extract_headers($out, $last_fetch, 1);
    $code //= 500;

    $self->INFO("$self->{cur_query}{method} $code $self->{cur_query}{fullpath}");
    return sub {
        my $responder = shift;

        my $writer = $responder->( [ $code, [%headers] ] );
        while ( $out->read( my $buf, $CHUNK_SIZE ) ) {
            $writer->write($buf);
        }
        $writer->close;
        close($out);
        # Wait on the script to do whatever it's doing after closing stdout
        $callback->() if ref $callback eq 'CODE';
    };
}

=head2 extract_headers($fh, $last_fetch)

Extract the headers from a filehandle.  Set the 'Last Modified' header appropriately based on the output of `stat` on the filehandle.

Returns a code and parsed headers hash.  Code will be 304 if the file hasn't changed since $last_fetch, otherwise will be the code in the parsed headers.

=cut

sub extract_headers {
    my ($fh, $last_fetch, $is_ref) = @_;
    my $headers = '';

    # NOTE: this is relying on while advancing the file pointer
    while (<$fh>) {
        last if $_ eq "\n";
        $headers .= $_;
    }
    my ( undef, undef, $status, undef, $headers_parsed ) = HTTP::Parser::XS::parse_http_response( "$headers\n", HEADERS_AS_HASHREF );

    my $code = $status // 200;
    $headers_parsed //= {};
    if (!$is_ref) {
        my $mt         = ( stat($fh) )[9];
        my @gm         = gmtime($mt);
        my $now_string = strftime( "%a, %d %b %Y %H:%M:%S GMT", @gm );
        $code       = $mt > $last_fetch ? $status : 304;
        $headers_parsed->{"Last-Modified"} = $now_string;
    }

    return ($code, %$headers_parsed);
}

sub static {
    my ( $self, $fullpath, $path, $start, $streaming, $last_fetch ) = @_;

    $self->DEBUG("Rendering static for $path");

    # XXX because of psgi I can't just vomit the file directly
    if ( open( my $fh, '<', "statics/$path" ) ) {
        my ($code, $headers_parsed) = (200, {});
        ($code, %$headers_parsed) = extract_headers($fh, $last_fetch );

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
    return $self->forbidden($self->{current_query});
}


1;
