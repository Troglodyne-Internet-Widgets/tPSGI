#!/usr/bin/env perl
# Use to call specific routes

use strict;
use warnings;

use FindBin::libs;
use FindBin;

chdir $FindBin::Bin;
$ENV{HOME}=$FindBin::Bin;

#Grab our custom routes
use TPSGI;

my %env = (
    REQUEST_METHOD => $ARGV[0],
    PATH_INFO      => $ARGV[1],
    QUERY_STRING   => $ARGV[2],
    REQUEST_URI    => 'http://localhost/'.$ARGV[1],
);

our $app = sub {
    my $self = TPSGI->new(TPSGI::get_config());
    return eval { $self->app(@_) } || do {
        my $env = shift;
        $env->{'psgi.errors'}->print($@);

        # Redact the stack trace past line 1, it usually has things which should not be shown
        $self->{cur_query}->{message} = $@;
        $self->{cur_query}->{message} =~ s/\n.*//g if $self->{cur_query}->{message};

        return $self->error($self->{cur_query});
    };
};
my $limit = $ARGV[3] || 1;
for ( 0 .. $limit ) {
    my $out = $app->( \%env );
    print $out->[2][0];
}
