package TPSGI::Startup;

# Lightweight startup helpers used by bin/tarbaby before the full TPSGI.pm
# is loaded into workers.  Keeping these separate means updating TPSGI.pm
# doesn't require restarting tarbaby to pick up get_config / inotify changes.

use strict;
use warnings;

use Cwd;
use File::Basename qw{dirname};
use File::Find;
use Scalar::Util qw{refaddr};
use Linux::Perl::inotify;
use Config::Simple;

our @wds;
our $inotify;

# wd => { path => ..., events => [...], restart => bool, callbacks => [ { key => ..., code => ... } ] }
our %watches;

# path => wd, so that we don't re-issue inotify_add_watch() needlessly.
our %watched;

# Whether watch_for_changes() has already set up the libdir watches.
our $watching = 0;

our @DEFAULT_EVENTS = qw{CREATE MODIFY DELETE MOVE};

# Bit => name for every event we can actually be handed back by read().
my %EVENT_NAMES = map { Linux::Perl::inotify->EVENT_NUMBER()->{$_} => $_ } qw{
  ACCESS MODIFY ATTRIB CLOSE_WRITE CLOSE_NOWRITE OPEN
  MOVED_FROM MOVED_TO CREATE DELETE DELETE_SELF MOVE_SELF
  UNMOUNT Q_OVERFLOW IGNORED ISDIR
};

=head2 get_config()

Read ~/.tpsgi.ini and return a merged options hash.

=cut

sub get_config {
    $ENV{HOME} ||= Cwd::getcwd();
    my %options = (
        verbose    => 0,
        custom_log => undef,
        routers    => [],
        loggers    => [],
        auth       => undef,
        domain     => '',
        user       => '',
        binds      => [],
        basedir    => '.',
        http_user  => '',
        tpsgi_dir  => Cwd::getcwd(),
        autoreload => 0,
    );
    my $config_file = "$ENV{HOME}/.tpsgi.ini";
    if ( -f $config_file ) {
        my $conf = Config::Simple->new($config_file);
        my %config;
        %config = %{ $conf->param( -block => 'default' ) } if $conf;

        foreach my $opt ( keys(%options) ) {
            if ( ref $options{$opt} eq 'ARRAY' ) {
                next unless exists $config{$opt};
                my @arrayed = ref $config{$opt} eq 'ARRAY' ? @{ $config{$opt} } : ( $config{$opt} );
                push( @{ $options{$opt} }, @arrayed );
                next;
            }
            $options{$opt} = $config{$opt} if exists $config{$opt};
        }
    }

    my $LOGNAME = "$options{tpsgi_dir}/log/tpsgi.log";
    $LOGNAME = $options{custom_log} if $options{custom_log};

    my $LOGDIR = dirname($LOGNAME);
    $options{log_dir}  = $LOGDIR;
    $options{log_name} = $LOGNAME;

    return %options;
}

=head2 watch_for_changes(@dirs)

Set up inotify watches on the given directories (and any .pm files within them).
These watches are flagged as 'restart' watches, which is what powers the
autoreload feature (see TPSGI::handle_changes).

Idempotent: no-op if the libdir watches are already active.

=cut

sub watch_for_changes {
    my (@dirs) = @_;

    return if $watching;
    $watching = 1;

    my @to_watch = _readdir(@dirs);

    foreach my $f2watch (@to_watch) {
        print "Watching $f2watch for changes\n";
        push( @wds, add_watch( path => $f2watch, restart => 1 ) );
    }

    return @wds;
}

=head2 add_watch(%args)

Add an arbitrary file or directory to the watchlist, optionally with a callback
to run when it changes.  Returns the inotify watch descriptor.

%args is:

=over

=item * C<path> - Required.  File or directory to watch.  When you watch a
directory you will be told about changes to the entries within it (but not
recursively); when you watch a file you are told about changes to that file.

=item * C<callback> - Optional CODE reference, called as
C<< $callback->($tpsgi, $change) >> by TPSGI::handle_changes() when the watched
path changes.  See that method for the shape of $change.

=item * C<key> - Optional string identifying the callback.  Registering the same
key twice replaces the prior callback rather than stacking a second one.
Defaults to the refaddr of the callback, which is what you want when you
register the same named sub or package-level closure repeatedly (TPSGI::new()
runs per request, so this happens constantly).

=item * C<events> - Optional ARRAY reference of inotify events to watch for.
Defaults to CREATE, MODIFY, DELETE and MOVE.  If the path is already watched,
any events not already in its mask are added to it.

=item * C<restart> - Optional boolean.  Marks this as a watch which should
restart the server when a .pm within it changes, if autoreload is on.

=back

=cut

sub add_watch {
    my (%args) = @_;

    my $path = $args{path};
    die "add_watch: path is required" unless defined $path && length $path;
    die "add_watch: callback must be a CODE reference" if defined $args{callback} && ref $args{callback} ne 'CODE';
    die "add_watch: events must be an ARRAY reference" if defined $args{events}   && ref $args{events} ne 'ARRAY';

    $inotify //= Linux::Perl::inotify->new( flags => [qw{NONBLOCK}] );

    my $events = $args{events} || [@DEFAULT_EVENTS];
    my $wd     = $watched{$path};

    if ( !defined $wd ) {
        $wd = $watched{$path} = $inotify->add( path => $path, events => $events );
        $watches{$wd} = {
            path      => $path,
            events    => [@$events],
            restart   => 0,
            callbacks => [],
        };
    }
    elsif ( $args{events} ) {

        # inotify_add_watch() *replaces* the mask by default, so union it in instead.
        my %have = map  { $_ => 1 } @{ $watches{$wd}{events} };
        my @new  = grep { !$have{$_} } @$events;
        if (@new) {
            $inotify->add( path => $path, events => [ @new, 'MASK_ADD' ] );
            push( @{ $watches{$wd}{events} }, @new );
        }
    }

    my $watch = $watches{$wd};
    $watch->{restart} ||= $args{restart} ? 1 : 0;

    if ( $args{callback} ) {
        my $key      = defined $args{key} ? $args{key} : refaddr( $args{callback} );
        my $existing = _find_callback( $watch, $key );
        if ($existing) {
            $existing->{code} = $args{callback};
        }
        else {
            push( @{ $watch->{callbacks} }, { key => $key, code => $args{callback} } );
        }
    }

    return $wd;
}

# Callbacks are kept in an array so that they fire in registration order.
sub _find_callback {
    my ( $watch, $key ) = @_;
    foreach my $cb ( @{ $watch->{callbacks} } ) {
        return $cb if $cb->{key} eq $key;
    }
    return undef;
}

=head2 is_watched($path)

Whether the passed path is already on the watchlist.

=cut

sub is_watched {
    my ($path) = @_;
    return defined $path && exists $watched{$path};
}

=head2 remove_watch($path)

Drop a path (and any callbacks registered against it) from the watchlist.

=cut

sub remove_watch {
    my ($path) = @_;

    my $wd = delete $watched{$path};
    return 0 unless defined $wd;

    delete $watches{$wd};
    @wds = grep { $_ != $wd } @wds;

    # The watch may already be gone (deleted file), so don't blow up over it.
    eval { $inotify->remove($wd) };

    return 1;
}

=head2 rewatch($wd)

Re-establish a watch which the kernel dropped out from under us.

Anything which writes a file "atomically" (write a tempfile, rename over the
target) destroys the watch on the old inode, so watches on individual files are
one-shot unless we put them back.  Returns the new watch descriptor, or undef
when the path is simply gone now.

=cut

sub rewatch {
    my ($wd) = @_;

    my $watch = delete $watches{$wd};
    return undef unless $watch;

    delete $watched{ $watch->{path} };
    my $was_libdir = grep { $_ == $wd } @wds;
    @wds = grep { $_ != $wd } @wds;

    # Nothing to re-watch if it didn't come back.
    return undef unless -e $watch->{path};

    my $new_wd = eval {
        add_watch(
            path    => $watch->{path},
            events  => $watch->{events},
            restart => $watch->{restart},
        );
    };
    return undef unless defined $new_wd;

    push( @{ $watches{$new_wd}{callbacks} }, @{ $watch->{callbacks} } );
    push( @wds,                              $new_wd ) if $was_libdir;

    return $new_wd;
}

=head2 event_names($mask)

Turn an inotify event mask into an ARRAY reference of event names.

=cut

sub event_names {
    my ($mask) = @_;
    return [ map { $EVENT_NAMES{$_} } grep { $mask & $_ } sort { $a <=> $b } keys(%EVENT_NAMES) ];
}

=head2 pending_changes()

Drain the inotify queue and return the changes as a list of HASH references:

    {
        path    => full path of the thing which changed,
        watched => the path we registered the watch against,
        events  => [ 'MODIFY', ... ],
        watch   => the watch entry this came from (undef if unknown to us),
        wd      => inotify watch descriptor,
        mask    => raw inotify mask,
        cookie  => raw inotify cookie,
        name    => raw inotify name (entry within a watched directory, if any),
    }

Note that the inotify instance is shared between all the workers forked off of
tarbaby, so whichever worker reads first consumes the event for everyone.  This
is why the callbacks you register need to be registered identically in every
worker (declare them in your router module, which every worker loads) and need
to be safe to run in any of them.

=cut

sub pending_changes {
    return () unless $inotify;

    my @changes;
    foreach my $event ( $inotify->read() ) {
        my $watch   = $watches{ $event->{wd} };
        my $watched = $watch ? $watch->{path} : '';
        $watched =~ s|/+$||;

        # Directory watches tell us the entry which changed, file watches don't.
        my $path = $watched;
        $path = length($watched) ? "$watched/$event->{name}" : $event->{name} if $event->{name};

        push(
            @changes,
            {
                %$event,
                path    => $path,
                watched => $watched,
                events  => event_names( $event->{mask} ),
                watch   => $watch,
            }
        );
    }

    return @changes;
}

sub _readdir {
    my @dirs = @_;
    File::Find::find(
        {
            wanted => sub {
                my $object = $_;
                push( @dirs, $object ) if ( -f $object && $object =~ m/\.pm$/ );
            },
            no_chdir => 1,
            bydepth  => 1,
        },
        @dirs
    );
    return @dirs;
}

1;
