package TestTPSGI;

# Minimal TPSGI subclass for unit testing.
# Bypasses new() system-user checks and replaces logging with no-ops so tests
# can call methods without Log::Dispatch setup or a real filesystem.

use strict;
use warnings;
use parent -norequire, 'TPSGI';

sub _make {
    my ($class, %extra) = @_;
    return bless {
        verbose  => 0,
        log_dir  => '/tmp',
        log_name => '/tmp/tpsgi-test.log',
        ip       => '127.0.0.1',
        %extra,
    }, $class;
}

# Override logging to be silent in tests
sub log     { bless { _silent => 1 }, 'TestTPSGI::Log' }
sub DEBUG   { }
sub INFO    { }
sub NOTE    { }
sub WARN    { }
sub ERROR   { }
sub CRIT    { }
sub ALERT   { }
sub EMERG   { }

# badrequest returns a recognisable PSGI triplet so tests can detect it
sub badrequest {
    my ($self, $query, $body) = @_;
    $body //= 'Bad Request';
    return [400, ['Content-Type' => 'text/plain'], [$body]];
}

package TestTPSGI::Log;
sub debug     { }
sub info      { }
sub notice    { }
sub warning   { }
sub error     { }
sub critical  { }
sub alert     { }
sub emergency { }

1;
