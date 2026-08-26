#!/usr/bin/env perl
# Use to call specific routes with the same configuration your website has

use strict;
use warnings;

use Data::Dumper;
use FindBin::libs;
use Carp::Always;

#Grab our custom routes
use TPSGI;

=head1 USAGE

    call.pl METHOD ROUTE QUERY_STRING COOKIE REPEAT_X_TIMES MAX_REDIRECTS

Max redirects default is 6.

=cut

my $host = $ENV{DOMAIN} // 'localhost';

my %env = (
    REQUEST_METHOD => $ARGV[0],
    PATH_INFO      => $ARGV[1],
    QUERY_STRING   => $ARGV[2],
    REQUEST_URI    => "http://$host/".$ARGV[1],
    HTTP_HOST      => $host,
    HTTP_COOKIE    => $ARGV[3],
    'psgi.errors'  => *STDERR,
    'psgi.input'   => *STDIN,
);

sub emit_error {
    my $env = shift;
    return $env->{'psgi.errors'}->print(shift) if $env->{'psgi.errors'};
    print $@;
}

my %cfg;
our $app = sub {
    # Allow re-run
    if (%cfg) {
        chdir($cfg{tpsgi_dir}) || warn "Can't chdir to $cfg{tpsgi_dir}: $_";
    }

    %cfg = TPSGI::get_config();

    # We are debugging here
    $cfg{verbose} = 1;

    # Change your dir into whatever basedir you need to be in
    chdir($cfg{'basedir'}) || warn "Can't chdir to $cfg{'basedir'}: $_";

    # If we have manually set the NYTPROF var, use it and don't try to control
    # When to stop or start it.
    $ENV{NYTPROF} ||= "sigexit=1:savesrc=0:start=no:file=$cfg{tpsgi_dir}/prof/nytprof.out";
    require Devel::NYTProf;
    mkdir "$cfg{tpsgi_dir}/prof";

    my $self = TPSGI->new(%cfg);
    local $@;

    return eval { $self->app(@_) } || do {
        my $env = shift;
        emit_error($env, $@);

        # Redact the stack trace past line 1, it usually has things which should not be shown
        $self->{cur_query}->{message} = $@;
        $self->{cur_query}->{message} =~ s/\n.*//g if $self->{cur_query}->{message};
        return $self->error($self->{cur_query});
    };
};

sub stream_to_stdout {
    my ($input) = @_;
    my ( $code, $headers ) = @$input;
    print "RC: $code\n";
    print "Headers:\n";
    print Dumper($headers);
    return \*STDOUT;
}

my $limit = $ARGV[4] || 1;
my $max_redirects = $ARGV[5] || 6;
my $redirects=0;

for ( 1 .. $limit ) {
    LOOP:
    my $out = $app->( \%env );

    if (ref $out eq 'CODE') {
        $out->(\&stream_to_stdout);
        next;
    }
    if (ref $out eq 'ARRAY') {
        # Might be a redirect, so check
        my $rc = $out->[0];
        my %hdr = @{$out->[1]};
        my $to = $hdr{Location};
        if ($to) {
            $env{REQUEST_URI} = "http://$host/$to";
            $env{PATH_INFO}   = $to;
            $redirects++;
            die "Max redirects reached!" unless $redirects < $max_redirects;
            goto LOOP;
        }

        print $out->[2][0];
        next;
    }
    die "Weird return:\n".Dumper($out);
}
