package Plack::Handler::TPSGI;

use strict;
use warnings;

use parent qw{Plack::Handler::Starman};

use TPSGI::Server;

=head1 Plack::Handler::TPSGI

Plack::Handler::Starman, running TPSGI::Server instead of Starman::Server.
bin/tarbaby asks Plack::Runner for it as C<server =E<gt> 'TPSGI'>.

=head2 run($app)

Plack::Handler::Starman::run() names Starman::Server outright, so this is
that, less its Server::Starter support, which tPSGI does not use.

=cut

sub run {
    my ( $self, $app ) = @_;

    my %nsa;
    foreach my $key ( keys %$self ) {
        ( my $name = $key ) =~ s/^net_server_// or next;
        $nsa{$name} = $self->{$key};
    }
    $self->{net_server_args} = \%nsa if %nsa;

    return TPSGI::Server->new->run( $app, {%$self} );
}

1;
