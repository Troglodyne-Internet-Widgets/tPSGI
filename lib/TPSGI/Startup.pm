package TPSGI::Startup;

# Lightweight startup helpers used by bin/tarbaby before the full TPSGI.pm
# is loaded into workers.  Keeping these separate means updating TPSGI.pm
# doesn't require restarting tarbaby to pick up get_config / inotify changes.

use strict;
use warnings;

use Cwd;
use File::Basename qw{dirname};
use File::Find;
use Linux::Perl::inotify;
use Config::Simple;

our @wds;
our $inotify;

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
Idempotent: no-op if watches are already active.

=cut

sub watch_for_changes {
    my (@dirs) = @_;

    return if @wds;

    $inotify //= Linux::Perl::inotify->new( flags => [qw{NONBLOCK}] );
    my @to_watch = _readdir(@dirs);

    foreach my $f2watch (@to_watch) {
        print "Watching $f2watch for changes\n";
        push( @wds, $inotify->add( path => $f2watch, events => [qw{CREATE MODIFY DELETE MOVE}] ) );
    }
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
