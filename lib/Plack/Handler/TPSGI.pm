package Plack::Handler::TPSGI;

# ABSTRACT: Plack::Handler::Starman, running TPSGI::Server

use 5.040;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Plack::Handler::Starman};

use TPSGI::Server;

=head1 Plack::Handler::TPSGI

Plack::Handler::Starman, running TPSGI::Server instead of Starman::Server.
bin/tarbaby asks Plack::Runner for it as C<server =E<gt> 'TPSGI'>.

=head2 run($app)

Plack::Handler::Starman::run() names Starman::Server outright, so this is
that, less its Server::Starter support, which tPSGI does not use.  Each option
whose name starts with C<net_server_> goes to Net::Server without that prefix.

=over 4

=item app - CodeRef - the PSGI application

=back

Returns what the run() of TPSGI::Server returns, when the server stops.

    Plack::Handler::TPSGI->new( port => 5000 )->run($app);

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
