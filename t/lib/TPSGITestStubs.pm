package TPSGITestStubs;

# Gracefully stub CPAN modules that may not be installed in the test environment.
# Pattern: try to load the real module first; stub only if unavailable.

use strict;
use warnings;

sub import {
    _stub_linux_inotify();
    _stub_config_simple();
    _stub_tpsgi_deps();
}

sub _stub_linux_inotify {
    return if eval { require Linux::Perl::inotify; 1 };

    # Minimal stub: new() returns an object with add() and read() methods.
    no warnings 'once';
    *Linux::Perl::inotify::new = sub {
        my ($class, %args) = @_;
        return bless { _wds => [], _events => [] }, $class;
    };
    *Linux::Perl::inotify::add = sub {
        my ($self, %args) = @_;
        my $wd = scalar(@{$self->{_wds}}) + 1;
        push @{$self->{_wds}}, $wd;
        return $wd;
    };
    *Linux::Perl::inotify::read = sub {
        my ($self) = @_;
        return @{ $self->{_events} };
    };
    $INC{'Linux/Perl/inotify.pm'} = 'stubbed';
}

sub _stub_config_simple {
    return if eval { require Config::Simple; 1 };
    *Config::Simple::new   = sub { bless {}, $_[0] };
    *Config::Simple::param = sub { return {} };
    $INC{'Config/Simple.pm'} = 'stubbed';
}

sub _stub_tpsgi_deps {
    _stub('HTTP::Body',             sub { bless { _params => {}, _uploads => {} }, $_[0] },
          param => sub { {} }, upload => sub { {} }, add => sub {} );
    _stub('HTTP::Parser::XS',       sub {},
          parse_http_response => sub { (1, 1, 200, 'OK', {}) },
          HEADERS_AS_HASHREF  => sub () { 1 } );
    # Also inject into HTTP::Parser::XS's caller namespace via the qw{} import
    {
        no strict 'refs'; no warnings 'once';
        *TPSGI::HEADERS_AS_HASHREF = sub () { 1 };
    }
    _stub('CGI::Emulate::PSGI',     sub {},
          emulate_environment => sub { {} } );
    _stub_simple('Date::Format',    strftime => sub { '' } );
    _stub_simple('Mojo::File',      new => sub { bless {}, $_[0] }, extname => sub { '' } );
    _stub_simple('IO::Compress::Gzip',  gzip => sub { 1 } );
    _stub_simple('URL::Encode',     url_params_mixed => sub { {} } );
    _stub_simple('File::Touch',     touch => sub { 1 } );
    _stub_simple('Log::Dispatch',   new => sub { bless { _dispatchers => [] }, $_[0] },
                                    add => sub {}, info => sub {}, debug => sub {},
                                    notice => sub {}, warning => sub {}, error => sub {},
                                    critical => sub {}, alert => sub {}, emergency => sub {},
                                    log_and_die => sub { die $_[2] } );
    _stub_simple('Log::Dispatch::Screen',     new => sub { bless {}, $_[0] } );
    _stub_simple('Log::Dispatch::FileRotate', new => sub { bless {}, $_[0] } );
    _stub_simple('UUID',            uuid => sub { 'test-uuid' } );
    _stub_simple('DateTime::Format::HTTP',
                 parse_datetime => sub { bless { epoch => 0 }, 'DateTime::Stub' } );
    _stub_simple('DateTime::Stub',  epoch => sub { 0 } );
    _stub_simple('Plack::MIME',     mime_type => sub { 'text/plain' } );
}

# Stub a module with a constructor and method list.
sub _stub {
    my ($mod, $ctor, %methods) = @_;
    my $inc_key = $mod; $inc_key =~ s|::|/|g; $inc_key .= '.pm';
    return if $INC{$inc_key};
    no strict 'refs'; no warnings 'redefine','once';
    *{"${mod}::new"} = $ctor;
    while (my ($name, $code) = each %methods) {
        *{"${mod}::${name}"} = $code;
    }
    $INC{$inc_key} = 'stubbed';
}

# Stub a module that exports functions (no OO constructor needed).
sub _stub_simple {
    my ($mod, %fns) = @_;
    my $inc_key = $mod; $inc_key =~ s|::|/|g; $inc_key .= '.pm';
    return if $INC{$inc_key};
    no strict 'refs'; no warnings 'redefine','once';
    while (my ($name, $code) = each %fns) {
        *{"${mod}::${name}"} = $code;
    }
    $INC{$inc_key} = 'stubbed';
}

1;
