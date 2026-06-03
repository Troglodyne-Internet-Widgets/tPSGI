#!/usr/bin/env perl

# Tests for TPSGI::serve() — static file serving without a real HTTP server.
# We call serve() directly on a blessed hashref to avoid new()'s user check.

use strict;
use warnings;

use Test::More;
use File::Temp qw{tempdir tempfile};
use Time::HiRes qw{gettimeofday};

use lib 't/lib';
use TPSGITestStubs;
use FindBin::libs;

use TPSGI;

my $tmpdir = tempdir(CLEANUP => 1);

my $user     = scalar getpwuid($>);
my $http_grp = (getgrgid($)))[0];

sub _make_tpsgi {
    my %extra = @_;
    return bless {
        user       => $user,
        http_user  => $http_grp,
        tpsgi_dir  => $tmpdir,
        basedir    => '.',
        log_dir    => $tmpdir,
        log_name   => "$tmpdir/tpsgi.log",
        verbose    => 0,
        autoreload => 0,
        indices    => [qw{index.html}],
        callbacks  => [],
        routes     => [],
        aliases    => {},
        ip         => '127.0.0.1',
        gid        => scalar(getgrnam($http_grp)),
        loggers    => [],
        %extra,
    }, 'TPSGI';
}

sub _start { return [gettimeofday] }

# ---- serve: basic file return (no compression) ----

subtest 'serve: returns 200 array response for existing text file' => sub {
    my ($fh, $path) = tempfile(DIR => $tmpdir, SUFFIX => '.txt', UNLINK => 1);
    print $fh 'Hello, world!';
    close $fh;

    my $tpsgi = _make_tpsgi();
    my $resp = $tpsgi->serve('/hello.txt', $path, _start(), 0, [], 0, 0);

    ok(ref $resp eq 'ARRAY', 'got arrayref response');
    is($resp->[0], 200, 'status 200');

    my %headers = @{ $resp->[1] };
    like($headers{'Content-type'}, qr{text/plain}, 'Content-type is text/plain');
    ok(exists $headers{'Content-Length'}, 'Content-Length present');
    is($headers{'Content-Length'}, 13, 'Content-Length = 13');
    ok(exists $headers{'Last-Modified'}, 'Last-Modified header present');
};

subtest 'serve: returns 200 for html file with correct MIME type' => sub {
    my ($fh, $path) = tempfile(DIR => $tmpdir, SUFFIX => '.html', UNLINK => 1);
    print $fh '<html><body>hi</body></html>';
    close $fh;

    my $tpsgi = _make_tpsgi();
    my $resp = $tpsgi->serve('/page.html', $path, _start(), 0, [], 0, 0);

    is($resp->[0], 200, 'status 200');
    my %headers = @{ $resp->[1] };
    like($headers{'Content-type'}, qr{text/html}, 'Content-type is text/html');
};

subtest 'serve: returns 304 when file not modified since last fetch' => sub {
    my ($fh, $path) = tempfile(DIR => $tmpdir, SUFFIX => '.txt', UNLINK => 1);
    print $fh 'old content';
    close $fh;

    my $mtime = (stat($path))[9];
    my $future = $mtime + 3600;     # pretend client fetched an hour after mtime

    my $tpsgi = _make_tpsgi();
    my $resp = $tpsgi->serve('/old.txt', $path, _start(), 0, [], $future, 0);

    is($resp->[0], 304, '304 when client cache is newer than file mtime');
};

subtest 'serve: returns 403 when file cannot be opened' => sub {
    my $tpsgi = _make_tpsgi();
    # Serve a nonexistent path — open() fails, should give 403
    my $resp = $tpsgi->serve('/secret.txt', '/this/path/does/not/exist.txt', _start(), 0, [], 0, 0);
    is($resp->[0], 403, '403 for unreadable/nonexistent file');
};

subtest 'serve: Accept-Ranges header present' => sub {
    my ($fh, $path) = tempfile(DIR => $tmpdir, SUFFIX => '.bin', UNLINK => 1);
    print $fh 'x' x 100;
    close $fh;

    my $tpsgi = _make_tpsgi();
    my $resp = $tpsgi->serve('/data.bin', $path, _start(), 0, [], 0, 0);

    my %headers = @{ $resp->[1] };
    is($headers{'Accept-Ranges'}, 'bytes', 'Accept-Ranges: bytes header set');
};

subtest 'serve: Server-Timing header appended' => sub {
    my ($fh, $path) = tempfile(DIR => $tmpdir, SUFFIX => '.txt', UNLINK => 1);
    print $fh 'timing test';
    close $fh;

    my $tpsgi = _make_tpsgi();
    my $resp = $tpsgi->serve('/timing.txt', $path, _start(), 0, [], 0, 0);

    my %headers = @{ $resp->[1] };
    ok(exists $headers{'Server-Timing'}, 'Server-Timing header present');
    like($headers{'Server-Timing'}, qr/dur=/, 'Server-Timing contains duration');
};

# ---- serve: streaming (large file) ----

subtest 'serve: returns CODE ref for streaming when file > CHUNK_SIZE' => sub {
    my ($fh, $path) = tempfile(DIR => $tmpdir, SUFFIX => '.dat', UNLINK => 1);
    # Write more than 1MB
    print $fh 'A' x ($TPSGI::CHUNK_SIZE + 1);
    close $fh;

    my $tpsgi = _make_tpsgi();
    my $resp = $tpsgi->serve('/large.dat', $path, _start(), 1, [], 0, 0);

    ok(ref $resp eq 'CODE', 'streaming response is a CODE ref for large files');

    # Drive the responder to ensure it completes without error
    my @written;
    my $writer = bless {
        write => sub { push @written, $_[1] },
        close => sub { },
    }, '_MockWriter';
    no strict 'refs';
    *{'_MockWriter::write'} = sub { push @written, $_[1] };
    *{'_MockWriter::close'} = sub { };
    use strict 'refs';

    my $responder = sub { return $writer };
    local $@;
    eval { $resp->($responder) };
    ok(!$@, 'streaming responder ran without exception');
    ok(@written > 0, 'data was written');
};

done_testing;
