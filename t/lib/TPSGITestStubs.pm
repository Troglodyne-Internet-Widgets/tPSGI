package TPSGITestStubs;

use strict;
use warnings;

# Graceful stub loader for CPAN deps not installed in the test environment.
# Prefers the real module when loadable; stubs only when missing.

sub import {
    _maybe_stub_inotify();
    _maybe_stub_http_parser_xs();
    _maybe_stub_log_dispatch();
    _maybe_stub_http_body();
    _maybe_stub_url_encode();
    _maybe_stub_cgi_emulate_psgi();
    _maybe_stub_misc();
}

sub _maybe_stub_inotify {
    return if eval { require Linux::Perl::inotify; 1 };
    no warnings 'once';
    $INC{'Linux/Perl/inotify.pm'} = 1;
    *Linux::Perl::inotify::new  = sub { bless {}, shift };
    *Linux::Perl::inotify::add  = sub { 1 };
    *Linux::Perl::inotify::read = sub { () };
}

sub _maybe_stub_http_parser_xs {
    return if eval { require HTTP::Parser::XS; 1 };
    $INC{'HTTP/Parser/XS.pm'} = 1;
    *HTTP::Parser::XS::parse_http_response = sub {
        my ($text, $flags) = @_;
        my %headers;
        my $status;
        for my $line ( split /\n/, $text ) {
            if ( $line =~ m{^HTTP/\S+\s+(\d+)} ) {
                $status = int($1);
            }
            elsif ( $line =~ /^([\w-]+):\s*(.+)$/ ) {
                $headers{ lc($1) } = $2;
            }
        }
        return ( undef, undef, $status, undef, \%headers );
    };
    *HTTP::Parser::XS::HEADERS_AS_HASHREF = sub () { 1 };
    unless ( defined &HTTP::Parser::XS::HEADERS_AS_HASHREF ) {
        no strict 'refs';
        *{'HTTP::Parser::XS::HEADERS_AS_HASHREF'} = sub () { 1 };
    }
    require Exporter;
    push @HTTP::Parser::XS::EXPORT_OK, 'HEADERS_AS_HASHREF';
    push @HTTP::Parser::XS::ISA,       'Exporter';
}

sub _maybe_stub_log_dispatch {
    return if eval { require Log::Dispatch; 1 };
    for my $mod (qw{ Log::Dispatch Log::Dispatch::Screen Log::Dispatch::FileRotate }) {
        ( my $path = "$mod.pm" ) =~ s{::}{/}g;
        $INC{$path} = 1;
    }
    my $noop = sub { 1 };
    no strict 'refs';
    *{'Log::Dispatch::new'} = sub { bless {}, shift };
    *{'Log::Dispatch::add'} = $noop;
    for my $level (qw{ debug info notice warning error critical alert emergency }) {
        *{"Log::Dispatch::$level"} = $noop;
    }
    *{'Log::Dispatch::log_and_die'} = sub { die $_[1]{message} // 'fatal' };
    *{'Log::Dispatch::Screen::new'}      = sub { bless {}, shift };
    *{'Log::Dispatch::FileRotate::new'}  = sub { bless {}, shift };
}

sub _maybe_stub_http_body {
    return if eval { require HTTP::Body; 1 };
    $INC{'HTTP/Body.pm'} = 1;
    *HTTP::Body::new    = sub { bless { param => {}, upload => {} }, shift };
    *HTTP::Body::add    = sub { 1 };
    *HTTP::Body::param  = sub { $_[0]{param} };
    *HTTP::Body::upload = sub { $_[0]{upload} };
}

sub _maybe_stub_url_encode {
    return if eval { require URL::Encode; 1 };
    $INC{'URL/Encode.pm'} = 1;
    *URL::Encode::url_params_mixed = sub {
        my $qs = shift // '';
        my %p;
        for my $pair ( split /&/, $qs ) {
            my ( $k, $v ) = split /=/, $pair, 2;
            $p{$k} = $v // '';
        }
        return \%p;
    };
}

sub _maybe_stub_cgi_emulate_psgi {
    return if eval { require CGI::Emulate::PSGI; 1 };
    $INC{'CGI/Emulate/PSGI.pm'} = 1;
    no strict 'refs';
    *{'CGI::Emulate::PSGI::emulate_environment'} = sub { () };
}

sub _maybe_stub_misc {
    for my $mod_spec (
        [ 'UUID',               [ [ 'UUID::uuid', sub { 'test-uuid' } ] ] ],
        [ 'Plack::MIME',        [ [ 'Plack::MIME::mime_type', sub { 'application/octet-stream' } ] ] ],
        [ 'IO::Compress::Gzip', [ [ 'IO::Compress::Gzip::gzip', sub { 1 } ] ] ],
        [ 'Config::Simple',     [ [ 'Config::Simple::new',   sub { bless {}, 'Config::Simple' } ],
                                  [ 'Config::Simple::read',  sub { 1 } ],
                                  [ 'Config::Simple::param', sub { () } ] ] ],
    ) {
        my ( $mod, $subs ) = @$mod_spec;
        next if eval { ( my $f = "$mod.pm" ) =~ s{::}{/}g; require $f; 1 };
        ( my $path = "$mod.pm" ) =~ s{::}{/}g;
        $INC{$path} = 1;
        no strict 'refs';
        for my $sub_spec (@$subs) {
            *{ $sub_spec->[0] } = $sub_spec->[1];
        }
    }

    # Mojo::File needs object methods
    unless ( eval { require Mojo::File; 1 } ) {
        $INC{'Mojo/File.pm'} = 1;
        no strict 'refs';
        *{'Mojo::File::new'}     = sub { my $c = shift; bless { path => shift }, $c };
        *{'Mojo::File::extname'} = sub { my $p = $_[0]{path}; $p =~ s/.*\.//; $p };
    }

    # DateTime::Format::HTTP needs class method + epoch instance method
    unless ( eval { require DateTime::Format::HTTP; 1 } ) {
        $INC{'DateTime/Format/HTTP.pm'} = 1;
        no strict 'refs';
        *{'DateTime::Format::HTTP::parse_datetime'} = sub { bless {}, 'DateTime::Format::HTTP' };
        *{'DateTime::Format::HTTP::epoch'}          = sub { 0 };
    }
}

1;
