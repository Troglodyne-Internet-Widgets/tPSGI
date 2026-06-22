#!/usr/bin/env perl
# Use to call specific routes with the same configuration your website has

use strict;
use warnings;

use Data::Dumper;
use FindBin::libs;
use Carp::Always;

#Grab our custom routes
use TPSGI;

my $host = $ENV{DOMAIN} // 'localhost';

my %env = (
    REQUEST_METHOD => $ARGV[0],
    PATH_INFO      => $ARGV[1],
    QUERY_STRING   => $ARGV[2],
    REQUEST_URI    => "http://$host/".$ARGV[1],
    HTTP_HOST      => $host,
    'psgi.errors'  => *STDERR,
    'psgi.input'   => *STDIN,
);

sub emit_error {
    my $env = shift;
    return $env->{'psgi.errors'}->print(shift) if $env->{'psgi.errors'};
    print $@;
}

our $app = sub {
    my %cfg = TPSGI::get_config();

    # We are debugging here
    $cfg{verbose} = 1;

    my $self = TPSGI->new(%cfg);
    local $@;

    chdir($cfg{'basedir'}) || warn "Can't chdir to $cfg{'basedir'}: $_";

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

my $limit = $ARGV[3] || 1;

for ( 1 .. $limit ) {
    my $out = $app->( \%env );
    if (ref $out eq 'CODE') {
        $out->(\&stream_to_stdout);
        next;
    }
    if (ref $out eq 'ARRAY') {
        print $out->[2][0];
        next;
    }
    die "Weird return:\n".Dumper($out);
}
