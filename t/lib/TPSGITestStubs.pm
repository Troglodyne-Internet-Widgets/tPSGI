package TPSGITestStubs;

# Graceful stub loader for CPAN modules not present in the test environment.
# Pattern: prefer real module when loadable; install stub only when missing.
# This avoids masking real load failures in environments where the module IS installed.

use strict;
use warnings;

sub install_stubs {
    _stub_if_missing('Linux::Perl::inotify', sub {
        package Linux::Perl::inotify;
        sub new  { bless {}, shift }
        sub add  { bless {}, 'Linux::Perl::inotify::WD' }
        sub read { () }
        package Linux::Perl::inotify::WD;
        sub DESTROY {}
    });

    _stub_if_missing('Log::Dispatch', sub {
        package Log::Dispatch;
        sub new     { bless { dispatchers => [] }, shift }
        sub add     { }
        sub debug   { }
        sub info    { }
        sub notice  { }
        sub warning { }
        sub error   { }
        sub critical    { }
        sub alert       { }
        sub emergency   { }
        sub log_and_die { die $_[2] }
    });

    _stub_if_missing('Log::Dispatch::Screen', sub {
        package Log::Dispatch::Screen;
        sub new { bless {}, shift }
    });

    _stub_if_missing('Log::Dispatch::FileRotate', sub {
        package Log::Dispatch::FileRotate;
        sub new { bless {}, shift }
    });

    _stub_if_missing('HTTP::Parser::XS', sub {
        package HTTP::Parser::XS;
        use constant HEADERS_AS_HASHREF => 1;
        sub parse_http_response {
            my ($raw, $mode) = @_;
            return (undef, undef, 200, undef, {});
        }
        sub import {
            my $class = shift;
            my $caller = caller;
            no strict 'refs';
            for my $sym (@_) {
                *{"${caller}::${sym}"} = \&{"${class}::${sym}"};
            }
        }
    });

    _stub_if_missing('HTTP::Body', sub {
        package HTTP::Body;
        sub new    { bless { _param => {}, _upload => {} }, shift }
        sub add    { }
        sub param  { $_[0]->{_param} }
        sub upload { $_[0]->{_upload} }
    });

    _stub_if_missing('URL::Encode', sub {
        package URL::Encode;
        sub url_params_mixed {
            my ($qs) = @_;
            return {} unless $qs;
            my %p;
            for my $pair (split /&/, $qs) {
                my ($k, $v) = split /=/, $pair, 2;
                $p{$k} = $v // '';
            }
            return \%p;
        }
    });

    _stub_if_missing('CGI::Emulate::PSGI', sub {
        package CGI::Emulate::PSGI;
        sub emulate_environment { {} }
    });

    _stub_if_missing('DateTime::Format::HTTP', sub {
        package DateTime::Format::HTTP;
        sub parse_datetime {
            my ($class, $str) = @_;
            return bless { epoch => 0 }, $class;
        }
        sub epoch { 0 }
    });
}

sub _stub_if_missing {
    my ($mod, $installer) = @_;
    eval "require $mod; 1" and return;
    $installer->();
    (my $file = "$mod.pm") =~ s{::}{/}g;
    $INC{$file} = '(stub)';
}

1;
