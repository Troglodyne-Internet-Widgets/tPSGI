package TPSGITestStubs;

# Graceful stub loader for CPAN deps not installed in the test environment.
# For each module: try the real one first; fall back to a minimal stub.

use strict;
use warnings;

my @STUBS = (
    # Log::Dispatch family — TPSGI::log() needs these
    sub {
        eval { require Log::Dispatch; 1 } and return;
        {
            no warnings 'once';
            $INC{'Log/Dispatch.pm'} = 1;
        }
        package Log::Dispatch;
        sub new { bless { dispatchers => [] }, shift }
        sub add {}
        sub info     { }
        sub debug    { }
        sub notice   { }
        sub warning  { }
        sub error    { }
        sub critical { }
        sub alert    { }
        sub emergency { }
        sub log_and_die { die $_[2] }
    },
    sub {
        eval { require Log::Dispatch::Screen; 1 } and return;
        $INC{'Log/Dispatch/Screen.pm'} = 1;
        package Log::Dispatch::Screen;
        sub new { bless {}, shift }
    },
    sub {
        eval { require Log::Dispatch::FileRotate; 1 } and return;
        $INC{'Log/Dispatch/FileRotate.pm'} = 1;
        package Log::Dispatch::FileRotate;
        sub new { bless {}, shift }
    },

    # HTTP::Parser::XS — used in extract_headers()
    sub {
        eval { require HTTP::Parser::XS; 1 } and return;
        $INC{'HTTP/Parser/XS.pm'} = 1;
        no strict 'refs';
        # Constant sub with () prototype so it inlines as bareword under strict
        *{'HTTP::Parser::XS::HEADERS_AS_HASHREF'} = sub () { 1 };
        # Use Exporter to handle the import() call from 'use HTTP::Parser::XS qw{...}'
        require Exporter;
        push @{'HTTP::Parser::XS::ISA'},       'Exporter';
        push @{'HTTP::Parser::XS::EXPORT_OK'}, 'HEADERS_AS_HASHREF', 'parse_http_response';
        *{'HTTP::Parser::XS::import'}          = \&Exporter::import;
        *{'HTTP::Parser::XS::parse_http_response'} = sub {
            my ( $buf, $flags ) = @_;
            my %h;
            my $status;
            for my $line ( split /\r?\n/, $buf ) {
                if ( $line =~ m{^HTTP/\S+\s+(\d+)} ) { $status = $1; next }
                if ( $line =~ /^([^:]+):\s*(.*)$/ ) { $h{$1} = $2 }
            }
            return ( undef, undef, $status, undef, \%h );
        };
    },

    # DateTime::Format::HTTP — used for If-Modified-Since parsing
    sub {
        eval { require DateTime::Format::HTTP; 1 } and return;
        $INC{'DateTime/Format/HTTP.pm'} = 1;
        package DateTime::Format::HTTP;
        sub parse_datetime {
            my ( $class, $str ) = @_;
            require HTTP::Date;
            my $epoch = HTTP::Date::str2time($str) // 0;
            return bless { epoch => $epoch }, $class;
        }
        sub epoch { $_[0]->{epoch} }
    },

    # URL::Encode — used in extract_query()
    sub {
        eval { require URL::Encode; 1 } and return;
        $INC{'URL/Encode.pm'} = 1;
        package URL::Encode;
        sub url_params_mixed {
            my ($qs) = @_;
            return {} unless defined $qs && length $qs;
            my %out;
            for my $pair ( split /&/, $qs ) {
                my ( $k, $v ) = split /=/, $pair, 2;
                $out{$k} = $v // '';
            }
            return \%out;
        }
    },

    # Linux::Perl::inotify — used in TPSGI::Startup
    sub {
        eval { require Linux::Perl::inotify; 1 } and return;
        $INC{'Linux/Perl/inotify.pm'} = 1;
        package Linux::Perl::inotify;
        sub new  { bless {}, shift }
        sub add  { }
        sub read { () }
    },

    # CGI::Emulate::PSGI — used in route() and cgi()
    sub {
        eval { require CGI::Emulate::PSGI; 1 } and return;
        $INC{'CGI/Emulate/PSGI.pm'} = 1;
        package CGI::Emulate::PSGI;
        sub emulate_environment { () }
    },

    # HTTP::Body — used in extract_query() for POST parsing
    sub {
        eval { require HTTP::Body; 1 } and return;
        $INC{'HTTP/Body.pm'} = 1;
        package HTTP::Body;
        sub new    { bless { param => {}, upload => {} }, shift }
        sub add    { }
        sub param  { $_[0]->{param} }
        sub upload { $_[0]->{upload} }
    },
);

sub import {
    $_->() for @STUBS;
}

1;
