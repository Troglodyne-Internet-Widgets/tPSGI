#!/usr/bin/env starman

use strict;
use warnings;

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
my $LOGNAME = -d '/var/log' ? '/var/log/www/perlfs.log' : '~/.perlfs/perlfs.log';
$LOGNAME = $ENV{CUSTOM_LOG} if $ENV{CUSTOM_LOG};

my $LEVEL = $ENV{WWW_VERBOSE} ? 'debug' : 'info';

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
    min_level => $ENV{DEBUG} ? 'debug' : 'error',
);
our $log = Log::Dispatch->new();
$log->add($rotate);
$log->add($screen);

#memoize
my $rq;
our $ip;
my $cur_query = {};

#XXX make perl -c quit whining
BEGIN {
    $ip   = '0.0.0.0';
}

sub _log {
    my ( $msg ) = @_;

    $msg //= "No message passed.  This is almost certainly a bug. ";

    #XXX Log lines must start as an ISO8601 date, anything else breaks fail2ban's beautiful mind
    my $tstamp = POSIX::strftime "%Y-%m-%dT%H:%M:%SZ", gmtime;

    return "$tstamp : $ip $msg\n";
}

sub INFO {
    $log->info( _log( shift ) );
}

# File serving
# Let's walk the directory and build our routes ahead of time.
my %routes;
File::Find::find({ wanted => sub {
    $routes{$_} = \&serve;
}, follow => 1, no_chdir => 1},
'www');

=head2 serve

Serve a file, with options to stream and cache the output.

=cut

sub serve {
    my ( $fullpath, $path, $start, $streaming, $ranges, $last_fetch, $deflate ) = @_;
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
        return _range( $fullpath, $fh, $ranges, $sz, @headers ) if @$ranges && $streaming;

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

        INFO("GET 200 $fullpath");

        # Append server-timing headers
        my $tot = tv_interval($start) * 1000;
        push( @headers, 'Server-Timing' => "file;dur=$tot" );

        return [ $code, \@headers, [$dfh] ];
    }

    INFO("GET 403 $fullpath");
    return [ 403, [ $ct => $content_types{text} ], ["Forbidden"] ];
}

sub _range {
    my ( $fullpath, $fh, $ranges, $sz, %headers ) = @_;
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
        INFO("GET 416 $fullpath");
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
    return [$code, [$ct => $content_types{text}], ["$type"]];
}

sub _notfound {
    my $query = shift;
    INFO("$query->{method} 404 $query->{fullpath}");
    return _generic( 'not found', 404 );
}

sub _forbidden {
    my $query = shift;
    INFO("$query->{method} 403 $query->{fullpath}");
    return _generic( 'forbidden', 403 );
}

sub _badrequest {
    my $query = shift;
    INFO("$query->{method} 400 $query->{fullpath}");
    return _generic( 'bad request', 400 );
}

sub _toolong {
    my $query = shift;
    INFO("$query->{method} 419 $query->{fullpath}");
    return _generic( 'URI too long', 419 );
}

sub _error {
    my $query = shift;
    INFO("$query->{method} 500 $query->{fullpath}");
    return _generic( 'Internal Server Error', 500 );
}

my %etags;
my $domain;
sub _app {
    # Start the server timing clock
    my $start = [gettimeofday];

    my $env = shift;

    # Discard the path used in the log, it's too long and enough 4xx error code = ban
    return _toolong({ method => $env->{REQUEST_METHOD}, fullpath => '...' }) if length( $env->{REQUEST_URI} ) > 2048;

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
    $cur_query = { route => $path, fullpath => $path, method => $method };

    # Check eTags.  If we don't know about it, just assume it's good and lazily fill the cache
    # XXX yes, this allows cache poisoning...but only for logged in users!
    if ( $env->{HTTP_IF_NONE_MATCH} ) {
        INFO("$env->{REQUEST_METHOD} 304 $fullpath");
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
    $ip = $env->{HTTP_X_FORWARDED_FOR} || $env->{REMOTE_ADDR};

    my $streaming = $env->{'psgi.streaming'};

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

    # Do a case insensitive match, because osx and windows
    my $file_actual = List::Util::first { lc($_) eq lc("www$path") } keys(%routes);

    # Dirindices
    if (!$file_actual) {
        my $dirindex = lc("www$path/index.htm");
        $dirindex =~ s|//|/|g;
        $file_actual = List::Util::first { index(lc($_), $dirindex) == 0  } keys(%routes);
    }

    my $file_is_cgi = $file_actual ? -x $file_actual : 0;
    return cgi( $env, $fullpath, $file_actual, $last_fetch, $deflate) if $file_is_cgi;
    return serve( $fullpath, $file_actual, $start, $streaming, \@ranges, $last_fetch, $deflate ) if $file_actual;
    return _notfound($cur_query);
}

# Read until we are done with headers, then pass off the filehandle to PSGI for streaming.
# TODO support compression
sub cgi {
    my ( $env, $fullpath, $file_actual, $last_fetch, $deflate) = @_;
    my $interpreter = $^X;

    # Setup the CGI vars they expect
    local %ENV = (%ENV, CGI::Emulate::PSGI->emulate_environment($env));

    my $pid = open(my $out, '-|', "$file_actual");
    my ($code, %headers) = _extract_headers($out, $last_fetch);
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


sub _extract_headers {
    my ($fh, $last_fetch) = @_;
    my $headers = '';

    # NOTE: this is relying on while advancing the file pointer
    while (<$fh>) {
        last if $_ eq "\n";
        $headers .= $_;
    }
    my ( undef, undef, $status, undef, $headers_parsed ) = HTTP::Parser::XS::parse_http_response( "$headers\n", HEADERS_AS_HASHREF );

    my $mt         = ( stat($fh) )[9];
    my @gm         = gmtime($mt);
    my $now_string = strftime( "%a, %d %b %Y %H:%M:%S GMT", @gm );
    my $code       = $mt > $last_fetch ? $status : 304;
    $headers_parsed->{"Last-Modified"} = $now_string;

    return ($code, %$headers_parsed);
}

our $app = sub {
    return eval { _app(@_) } || do {
		my $env = shift;
        $env->{'psgi.errors'}->print($@);

		# Redact the stack trace past line 1, it usually has things which should not be shown
		$cur_query->{message} = $@;
		$cur_query->{message} =~ s/\n.*//g if $cur_query->{message};

		return _error($cur_query);
    };
};


