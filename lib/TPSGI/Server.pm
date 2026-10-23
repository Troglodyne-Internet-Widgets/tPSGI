package TPSGI::Server;

# ABSTRACT: Starman::Server, with workers that answer the connection they took before a HUP retires them

use 5.040;
use warnings FATAL => 'all';
use re '/aasx';

use parent qw{Starman::Server};

=head1 TPSGI::Server

Starman::Server, with workers that answer every connection they accept before
a HUP retires them.

=head2 Why

A HUP to Starman's parent sends HUP to every worker.  Net::Server::PreFork's
handler for it exits on the spot unless the worker is C<connected>, and
run_child() only sets that flag in the statement after accept() returns.  Perl
runs the handler between those two, so a worker which had just accepted a
connection exited holding it: the kernel reset the connection, and nginx
answered the client with a 502.  tPSGI HUPs its parent after every save, and
the browser's next request lands exactly then.

Here the handler only marks the worker HUPed and done, and accept() returns 1
whenever it is holding a connection.  A worker blocked in accept() still
retires at once, since the HUP interrupts the accept and nothing was taken.  One
which took a connection answers it, and done() retires it afterwards, as it
does a worker that was busy when the HUP came.

This depends on how Net::Server's accept() and run_child() use C<_HUP>,
C<SigHUPed> and C<client>.  t/TPSGI-Server.t pins that.

=head2 child_init_hook

Starman's, then the HUP handler described above.  It replaces the one
Net::Server::PreFork installs in run_child(), which runs before this hook.

=cut

sub child_init_hook {
    my $self = shift;
    $self->SUPER::child_init_hook(@_);

    my $prop = $self->{server};

    # For the life of the worker, so not localized.
    $SIG{HUP} = sub {    ## no critic (RequireLocalizedPunctuationVars)
        $prop->{SigHUPed} = 1;

        # Makes Net::Server's accept() return rather than retry, so a worker
        # waiting in it retires now instead of after its next request.
        $prop->{_HUP} = 1;
    };
    return;
}

=head2 accept() = BOOL

True when there is a connection to answer, even when a HUP made
Net::Server::accept() say otherwise.

=cut

sub accept {    ## no critic (ProhibitBuiltinHomonyms) -- Net::Server's method, overridden
    my $self = shift;
    my $prop = $self->{server};

    # So a connection from the last request cannot pass for a new one.
    delete $prop->{client};

    return 1 if $self->SUPER::accept(@_);
    return $prop->{client} ? 1 : 0;
}

1;
