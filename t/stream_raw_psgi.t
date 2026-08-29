use strict;
use warnings;

use FindBin qw{$Bin};
use lib "$Bin/lib";

use TPSGITestStubs;
BEGIN { TPSGITestStubs::install_stubs() }

use lib "$Bin/../lib";
use TPSGI;
use TestTPSGI;

use Test::More;
use IO::Handle;

# ---------------------------------------------------------------------------
# stream_raw_psgi: must write ALL body elements, not just the first
# ---------------------------------------------------------------------------
#
# Bug: the previous code did `print $fh $response->[2][0]` which discarded
# all body elements after the first.  For a multi-chunk PSGI response body
# (an arrayref of strings), only the first chunk was sent.

sub _make_tpsgi_with_pipe {
    # Returns ($tpsgi, $read_fh) where stream_raw_psgi will write to write_fh
    # and we can read what was emitted via read_fh.
    my ($rh, $wh);
    pipe($rh, $wh) or die "pipe: $!";
    $wh->autoflush(1);

    my $tpsgi = TestTPSGI->_make(
        filehandle => $wh,
        verbose    => 0,
    );
    return ($tpsgi, $rh, $wh);
}

sub _slurp_nonblocking {
    my ($fh, $wh) = @_;
    close($wh);   # signal EOF to reader
    local $/;
    return <$fh>;
}

sub _make_data {
    return {
        start      => [Time::HiRes::gettimeofday()],
        fullpath   => '/test',
        callbacks  => [],
    };
}

use Time::HiRes;

# --- Test 1: single-element body is written ---
{
    my ($tpsgi, $rh, $wh) = _make_tpsgi_with_pipe();
    my $response = [200, ['Content-Type' => 'text/plain', 'Content-Length' => 5], ['hello']];
    my $data = _make_data();
    $tpsgi->{callbacks} = [];

    # stream_raw_psgi calls exit(0) at the end; run in a fork so the test process survives
    my $pid = fork();
    die "fork failed: $!" unless defined $pid;
    if ($pid == 0) {
        $tpsgi->stream_raw_psgi($response, $data);
        exit 0;
    }
    close($wh);
    local $/;
    my $output = <$rh>;
    waitpid($pid, 0);

    like($output, qr/hello/, 'single-element body: content present');
    like($output, qr/200/,   'single-element body: status line present');
}

# --- Test 2: multi-element body — all chunks written ---
{
    my ($tpsgi, $rh, $wh) = _make_tpsgi_with_pipe();
    my $response = [200,
        ['Content-Type' => 'text/plain'],
        ['chunk-one ', 'chunk-two ', 'chunk-three'],
    ];
    my $data = _make_data();
    $tpsgi->{callbacks} = [];

    my $pid = fork();
    die "fork failed: $!" unless defined $pid;
    if ($pid == 0) {
        $tpsgi->stream_raw_psgi($response, $data);
        exit 0;
    }
    close($wh);
    local $/;
    my $output = <$rh>;
    waitpid($pid, 0);

    like($output, qr/chunk-one/,   'multi-element body: first chunk present');
    like($output, qr/chunk-two/,   'multi-element body: second chunk present');
    like($output, qr/chunk-three/, 'multi-element body: third chunk present');
}

# --- Test 3: empty body array does not crash ---
{
    my ($tpsgi, $rh, $wh) = _make_tpsgi_with_pipe();
    my $response = [204, ['Content-Length' => '0'], []];
    my $data = _make_data();
    $tpsgi->{callbacks} = [];

    my $pid = fork();
    die "fork failed: $!" unless defined $pid;
    if ($pid == 0) {
        $tpsgi->stream_raw_psgi($response, $data);
        exit 0;
    }
    close($wh);
    local $/;
    my $output = <$rh>;
    waitpid($pid, 0);

    like($output, qr/204/, 'empty body: status line written without crash');
}

done_testing();
