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

# ---------------------------------------------------------------------------
# extract_query: parameter whitelist must include capture names and data keys
# ---------------------------------------------------------------------------
#
# Bug: when a route defines `parameters` (strict validation mode), only keys in
# `%$parameters` were whitelisted.  Capture fields injected by the route regex
# and static data fields from `route->{data}` were not added to the whitelist,
# causing any route that combined captures + strict parameters to return a
# spurious 400 Bad Request for every valid request.

my $tpsgi = TestTPSGI->_make();

sub _env {
    my (%overrides) = @_;
    return {
        REQUEST_METHOD  => 'GET',
        QUERY_STRING    => '',
        CONTENT_TYPE    => 'text/html',
        CONTENT_LENGTH  => 0,
        'psgi.input'    => do { open my $fh, '<', \(my $s = ''); $fh },
        %overrides,
    };
}

# Helper: build a minimal route hashref
sub _route {
    my (%opts) = @_;
    return {
        method    => 'GET',
        callbacks => { '*' => sub { [200, [], ['ok']] } },
        %opts,
    };
}

# --- Test 1: no parameters hash → any fields pass through ---
{
    my $route = _route(
        pattern  => '/thing',
        captures => ['id'],
    );
    my $env = _env();
    my $q = $tpsgi->extract_query('/thing/42', $route, $env);
    isnt(ref $q, 'ARRAY', 'no strict mode: extract_query returns hashref');
}

# --- Test 2: captures whitelisted when parameters is defined ---
{
    my $route = _route(
        pattern    => '/user/(\d+)',
        captures   => ['user_id'],
        parameters => { user_id => sub { $_[0] =~ /^\d+$/ } },
    );
    my $env = _env(QUERY_STRING => '');
    my $q = $tpsgi->extract_query('/user/42', $route, $env);
    isnt(ref $q, 'ARRAY',
        'capture key whitelisted: no spurious 400 when parameters is defined');
    is($q->{user_id}, '42', 'capture value populated correctly');
}

# --- Test 3: multiple captures all whitelisted ---
{
    my $route = _route(
        pattern    => '/blog/(\d+)/comment/(\d+)',
        captures   => ['post_id', 'comment_id'],
        parameters => {
            post_id    => sub { $_[0] =~ /^\d+$/ },
            comment_id => sub { $_[0] =~ /^\d+$/ },
        },
    );
    my $env = _env(QUERY_STRING => '');
    my $q = $tpsgi->extract_query('/blog/7/comment/13', $route, $env);
    isnt(ref $q, 'ARRAY', 'multiple captures all whitelisted');
    is($q->{post_id},    '7',  'post_id capture correct');
    is($q->{comment_id}, '13', 'comment_id capture correct');
}

# --- Test 4: data keys whitelisted when parameters is defined ---
{
    my $route = _route(
        pattern    => '/static',
        data       => { section => 'blog', theme => 'dark' },
        parameters => { title => sub { length($_[0]) < 200 } },
    );
    my $env = _env(QUERY_STRING => 'title=Hello');
    my $q = $tpsgi->extract_query('/static', $route, $env);
    isnt(ref $q, 'ARRAY',
        'data keys whitelisted: no spurious 400 when parameters is defined');
    is($q->{section}, 'blog', 'data field section preserved');
    is($q->{theme},   'dark', 'data field theme preserved');
}

# --- Test 5: captures + data + user-supplied param all whitelisted together ---
{
    my $route = _route(
        pattern    => '/feed/(\w+)',
        captures   => ['format'],
        data       => { layout => 'full' },
        parameters => {
            format => sub { $_[0] =~ /^(?:rss|atom|json)$/ },
            page   => sub { $_[0] =~ /^\d+$/ },
        },
    );
    my $env = _env(QUERY_STRING => 'page=2');
    my $q = $tpsgi->extract_query('/feed/rss', $route, $env);
    isnt(ref $q, 'ARRAY', 'captures + data + param coexist without 400');
    is($q->{format}, 'rss',  'capture format correct');
    is($q->{layout}, 'full', 'data layout correct');
    is($q->{page},   '2',    'user param page correct');
}

# --- Test 6: invalid capture value rejected by its validator ---
{
    my $route = _route(
        pattern    => '/user/(\w+)',
        captures   => ['user_id'],
        parameters => { user_id => sub { $_[0] =~ /^\d+$/ } },
    );
    my $env = _env(QUERY_STRING => '');
    # Path capture would give user_id = 'notanumber'
    my $q = $tpsgi->extract_query('/user/notanumber', $route, $env);
    is(ref $q, 'ARRAY', 'invalid capture value triggers 400');
    is($q->[0], 400,    '400 status returned for bad capture');
}

# --- Test 7: unknown param rejected in strict mode ---
{
    my $route = _route(
        pattern    => '/search',
        parameters => { q => sub { length($_[0]) < 100 } },
    );
    my $env = _env(QUERY_STRING => 'q=hello&evil=1');
    my $q = $tpsgi->extract_query('/search', $route, $env);
    is(ref $q, 'ARRAY', 'unknown param rejected in strict mode');
    is($q->[0], 400,    '400 status for unexpected param');
}

# --- Test 8: empty parameters hash skips strict validation ---
{
    my $route = _route(
        pattern    => '/open',
        parameters => {},
    );
    my $env = _env(QUERY_STRING => 'foo=bar&baz=qux');
    my $q = $tpsgi->extract_query('/open', $route, $env);
    isnt(ref $q, 'ARRAY', 'empty parameters hash: strict mode inactive, any params pass');
}

done_testing();
