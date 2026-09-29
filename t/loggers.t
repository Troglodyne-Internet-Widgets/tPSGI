use strict;
use warnings;

use Test2::V0;
use Test2::Plugin::NoWarnings;

use Cwd            qw{abs_path};
use File::Path     qw{make_path};
use File::Temp     qw{tempdir};
use File::Basename qw{dirname};

use lib dirname( abs_path(__FILE__) ) . '/../lib';

use TPSGI;

# A logger named in the configuration is a class that nothing has loaded yet.
# An application ships it beside its router, and TPSGI logs its first line
# while it is still loading that router.
my $dir = tempdir( CLEANUP => 1 );
my $lib = "$dir/lib";
make_path("$lib/Test/Logger");

open( my $fh, '>', "$lib/Test/Logger/Capture.pm" ) or die "Cannot write the test logger: $!";
print $fh <<'LOGGER';
package Test::Logger::Capture;
use strict;
use warnings;
use parent qw{Log::Dispatch::Output};

our @lines;
our %given;

sub new {
    my ( $class, %p ) = @_;
    %given = %p;
    my $self = bless {}, $class;
    $self->_basic_init( name => 'capture', min_level => $p{min_level} );
    return $self;
}

sub log_message {
    my ( $self, %p ) = @_;
    push( @lines, $p{message} );
    return;
}

1;
LOGGER
close($fh);

push( @INC, $lib );

my $tpsgi = bless(
    {
        log_name => "$dir/tpsgi.log",
        log_dir  => $dir,
        verbose  => 0,
        loggers  => ['Test::Logger::Capture'],
        ip       => '0.0.0.0',
    },
    'TPSGI'
);

ok( lives { $tpsgi->log }, 'a logger class that nothing loaded is loaded by name' ) or note $@;

no warnings 'once';
is( $Test::Logger::Capture::given{log_dir},   $dir,   'it is handed the log directory' );
is( $Test::Logger::Capture::given{min_level}, 'info', 'and the level' );
like( \@Test::Logger::Capture::lines, [qr/Opening Log/], 'and it receives the lines that the file gets' );

# The name becomes a path to load, so only a module name is one.
my $refusing = bless( { %$tpsgi, loggers => ['../../etc/passwd'] }, 'TPSGI' );
like( dies { TPSGI::_build_log($refusing) }, qr/not a module name/, 'a logger that is not a module name is refused' );

done_testing();
