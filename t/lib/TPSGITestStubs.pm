package TPSGITestStubs;

# Stubs for TPSGI dependencies that may not be installed in the test environment.
# Each stub first attempts to load the real module — if that succeeds we do
# nothing. Only when the real module is absent do we register a minimal fake.
#
# Load this BEFORE 'use TPSGI' or 'use TPSGI::Startup' so Perl won't try
# to find the missing .pm files on disk.

use strict;
use warnings;

sub import {
    _maybe_stub('Linux::Perl::inotify',            'Linux/Perl/inotify.pm',            \&_stub_linux_perl_inotify);
    _maybe_stub('HTTP::Parser::XS',                'HTTP/Parser/XS.pm',                \&_stub_http_parser_xs);
    _maybe_stub('HTTP::Body',                      'HTTP/Body.pm',                     \&_stub_http_body);
    _maybe_stub('CGI::Emulate::PSGI',              'CGI/Emulate/PSGI.pm',              \&_stub_cgi_emulate_psgi);
    _maybe_stub('Log::Dispatch',                   'Log/Dispatch.pm',                  \&_stub_log_dispatch);
    _maybe_stub('Log::Dispatch::Screen',           'Log/Dispatch/Screen.pm',           \&_stub_log_dispatch_screen);
    _maybe_stub('Log::Dispatch::FileRotate',       'Log/Dispatch/FileRotate.pm',       \&_stub_log_dispatch_filerotate);
    _maybe_stub('URL::Encode',                     'URL/Encode.pm',                    \&_stub_url_encode);
    _maybe_stub('DateTime::Format::HTTP',          'DateTime/Format/HTTP.pm',          \&_stub_datetime_format_http);
}

sub _maybe_stub {
    my ($pkg, $path, $stubber) = @_;
    return if $INC{$path};                       # already loaded (real or stubbed)
    return if eval { require $path; 1 };         # real module loadable — use it
    $stubber->();                                # install the stub
}

sub _stub_linux_perl_inotify {
    package Linux::Perl::inotify;
    sub new  { bless { _wds => [] }, shift }
    sub add  { my $self = shift; my $wd = {}; push @{$self->{_wds}}, $wd; return $wd }
    sub read { return () }
    $INC{'Linux/Perl/inotify.pm'} = 1;
    package TPSGITestStubs;
}

sub _stub_http_parser_xs {
    package HTTP::Parser::XS;
    use constant HEADERS_AS_HASHREF => 1;
    sub parse_http_response {
        my ($buf, $mode) = @_;
        my ($status, $message) = (undef, 'OK');
        my %headers;
        for my $line (split /\r?\n/, $buf) {
            if ($line =~ m{^HTTP/1\.(\d)\s+(\d+)\s+(.+)}) {
                $status  = $2 + 0;
                $message = $3;
            } elsif ($line =~ m{^([^:]+):\s*(.+)}) {
                $headers{lc $1} = $2;
            }
        }
        return (1, undef, $status, undef, \%headers);
    }
    sub import {
        my $class  = shift;
        my $caller = caller;
        no strict 'refs';
        for my $sym (@_) {
            *{"${caller}::${sym}"} = \&{"HTTP::Parser::XS::${sym}"};
        }
    }
    $INC{'HTTP/Parser/XS.pm'} = 1;
    package TPSGITestStubs;
}

sub _stub_http_body {
    package HTTP::Body;
    sub new    { bless { params => {}, upload => {} }, shift }
    sub add    { }
    sub param  { $_[0]->{params} }
    sub upload { $_[0]->{upload} }
    $INC{'HTTP/Body.pm'} = 1;
    package TPSGITestStubs;
}

sub _stub_cgi_emulate_psgi {
    package CGI::Emulate::PSGI;
    sub emulate_environment { return () }
    $INC{'CGI/Emulate/PSGI.pm'} = 1;
    package TPSGITestStubs;
}

sub _stub_log_dispatch {
    package Log::Dispatch;
    sub new { bless { handlers => [] }, shift }
    sub add { push @{$_[0]{handlers}}, $_[1] }
    {
        no strict 'refs';
        for my $lvl (qw{debug info notice warning error critical alert emergency}) {
            *{"Log::Dispatch::$lvl"} = sub { };
        }
        *{"Log::Dispatch::log_and_die"} = sub { die $_[-1] };
    }
    $INC{'Log/Dispatch.pm'} = 1;
    package TPSGITestStubs;
}

sub _stub_log_dispatch_screen {
    package Log::Dispatch::Screen;
    sub new { bless {}, shift }
    $INC{'Log/Dispatch/Screen.pm'} = 1;
    package TPSGITestStubs;
}

sub _stub_log_dispatch_filerotate {
    package Log::Dispatch::FileRotate;
    sub new { bless {}, shift }
    $INC{'Log/Dispatch/FileRotate.pm'} = 1;
    package TPSGITestStubs;
}

sub _stub_url_encode {
    package URL::Encode;
    sub url_params_mixed {
        my $qs = shift // '';
        my %params;
        for my $pair (split /&/, $qs) {
            my ($k, $v) = split /=/, $pair, 2;
            next unless defined $k && length $k;
            $k =~ s/\+/ /g; $k =~ s/%([0-9A-Fa-f]{2})/chr hex $1/ge;
            $v //= ''; $v =~ s/\+/ /g; $v =~ s/%([0-9A-Fa-f]{2})/chr hex $1/ge;
            $params{$k} = $v;
        }
        return \%params;
    }
    $INC{'URL/Encode.pm'} = 1;
    package TPSGITestStubs;
}

sub _stub_datetime_format_http {
    package DateTime::Format::HTTP;
    sub parse_datetime { bless { epoch => 0 }, ref($_[0]) || $_[0] }
    sub epoch          { $_[0]->{epoch} }
    $INC{'DateTime/Format/HTTP.pm'} = 1;
    package TPSGITestStubs;
}

1;
