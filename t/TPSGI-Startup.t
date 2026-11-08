#!/usr/bin/env perl
use 5.040;
use warnings FATAL => 'all';
use re '/aasx';

use Test2::V0;
use Test2::Plugin::NoWarnings;

use File::Path ();
use File::Temp ();

use FindBin::libs;

ok( require TPSGI::Startup, 'TPSGI::Startup loads' ) or bail_out("Can't find SUT");

# Real files rather than mocked ones, since a hard link is what is under test.
sub write_file ( $path, $body ) {
    open( my $fh, '>', $path ) or die "Could not write $path: $!";
    print {$fh} $body;
    close($fh) or die "Could not close $path: $!";
    return;
}

sub read_file ($path) {
    open( my $fh, '<', $path ) or return;
    my $body = do { local $/; <$fh> };
    close($fh) or die "Could not close $path: $!";
    return $body;
}

subtest 'sweep_statics' => sub {
    my $root = File::Temp::tempdir( CLEANUP => 1 );
    File::Path::make_path( map { "$root/$_" } qw{app/www/styles www/static/styles} );
    my %options = ( tpsgi_dir => $root, basedir => 'app' );

    # What serve() leaves: each file of the app's www/ linked into the statics.
    write_file( "$root/app/www/styles/$_.css", "$_ as it was" ) foreach qw{kept replaced};
    link( "$root/app/www/styles/$_.css", "$root/www/static/styles/$_.css" ) or die $! foreach qw{kept replaced};

    # An update replaces a file, as git and mv do, rather than writing into it.
    unlink "$root/app/www/styles/replaced.css" or die $!;
    write_file( "$root/app/www/styles/replaced.css", 'replaced as it is now' );

    # A render, which no file of the app's www/ stands behind.
    write_file( "$root/www/static/page.html", 'a render' );

    my @removed = TPSGI::Startup::sweep_statics(%options);
    is( \@removed, ["$root/www/static/styles/replaced.css"], 'the link to a file that an update replaced is removed, and returned' );
    ok( !-e "$root/www/static/styles/replaced.css", 'so nginx sends the next request for it to serve()' );
    is( read_file("$root/www/static/styles/kept.css"), 'kept as it was', 'a link to a file that is unchanged stays' );
    is( read_file("$root/www/static/page.html"),       'a render',       'and so does a render' );

    is( [ TPSGI::Startup::sweep_statics(%options) ],                                     [], 'a second sweep finds nothing' );
    is( [ TPSGI::Startup::sweep_statics( tpsgi_dir => "$root/bogus", basedir => '.' ) ], [], 'and an install with no statics is nothing to sweep' );
};

done_testing();
