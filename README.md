# NAME

TPSGI - Abstraction layer around starman to become a general purpose HTTP server & static renderer.

# VERSION

version 0.001

# SYNOPSIS

A router module, which `routers` in `~/.tpsgi.ini` names:

```perl
package My::Routes;
use Mojo::JSON ();

our %openapi = (
    openapi => '3.0.3',
    info    => { title => 'My routes', version => '1' },
    paths   => {
        '/hello' => {
            get => {
                'x-tpsgi-callback' => \&hello,
                responses          => { 200 => { description => 'A greeting' } },
            },
        },
    },
);

sub hello {
    my ( $tpsgi, $query ) = @_;
    return [ 200, [ 'Content-Type' => 'text/html' ], ['Hello world'] ];
}
```

# DESCRIPTION

Start it with the Starman options you want, from the directory of the
application, with tarbaby on the PATH:

```
tpsgi ... [starman args]
```

A PSGI server built to migrate old mod\_perl/apache stacks onto psgi, and that powers tCMS.

Will execute any executable file (chmod +x) in www/ as CGI, and otherwise host any static file therein.

The idea here is as a bridge between old and new which allows you to modernize at your own pace, gradually turning CGIs into routes.

The other idea is that we don't want to add any extra abstraction if we don't have to, while gently guiding into better practices.
Shops used to having full control over the HTTP response should continue to do so, rather than being locked into one framework or another.
This allows them to continue doing whatever funky thing they have been doing, like COMET, et cetera.
The best way to do that is to expect raw PSGI to be output.

## request\_id($regenerate) = STRING

The UUID of the request being answered, which every log line carries.  A true
$regenerate makes a new one, which app() does as each request comes in.

## log() = Log::Dispatch

The process's Log::Dispatch, made by build\_log() the first time it is asked
for.

## build\_log() = Log::Dispatch

A new Log::Dispatch from the options: the rotated file at `log_name`, the
screen, and each class that `loggers` names, which is loaded by name.  log()
keeps the first one this makes.

## DEBUG, INFO, NOTE, WARN, ERROR, CRIT, ALERT, EMERG, FATAL($message)

Log $message at that level, stamped with the time, the worker, the request and
the user.  FATAL logs at the emergency level and then dies with the line.

## new(%options)

Load the routers, and build the TPSGI::Router of their `%openapi` documents.
It dies unless it runs as `user`, and `http_user` and `tpsgi_dir` are set.
It also dies when a router does not load, when its document is not one that
TPSGI::Router accepts, and when a router still defines `@routes` instead of
`%openapi`.

new() runs for every request, and compiling a document takes much longer than
answering one.  So the router is built once in each worker, for each list of
router files, and kept.  A HUP replaces the workers, so a changed router is
compiled again.

get\_config() returns the options, and among them are:

```
custom_log
verbose
routers
loggers
auth
```

## indices() = ARRAYREF

The directory index files, in the order they are tried: the `indices` option,
then `index.html`, `index.htm` and `index.cgi`.

## routes() = TPSGI::Router

The router that new() built from the `%openapi` of every router.

## serve($fullpath, $path, $start, $streaming, $ranges, $last\_fetch, $deflate)

Serve a file, with options to stream and cache the output.

## serve\_ranges($fh, $ranges, %args) = PSGI response

Answer a Range request from $fh with a 206, or a 416 when a range is outside
the file.  $ranges is what parse\_ranges() returns, and %args is `size`, the
size of the file, `headers`, a HASH reference of the response headers so far,
and `fullpath`, the URL for the log.  More than one range is answered as
multipart/byteranges.

## redirect, redirect\_permanent, see\_also

Redirects to the provided page.

## ok

Return a generic HTTP 200 OK

## notfound, forbidden, badrequest, notallowed, unsupported, toolong, error, unavailable

If you need to return these HTTP errors, return these within a route:

```perl
sub route {
    my ($self, $query) = @_;
    ...
    return $self->notfound($query);
}
```

## app($env) = PSGI response

The PSGI application: respond() to the request, or answer it with error() when
that dies.

## cannot\_start($error, $env, %options) = ARRAYREF

What to answer with when new() died, so there is no object to answer with.
Usually a router that would not load: a missing module, a syntax error.

The error goes to psgi.errors, and to the log by way of a stand-in built from
the same options, so it lands in the same places a request's own errors do.  If
building the log is what failed -- a logger that will not load -- psgi.errors
is all there is, and the answer is still a 500 rather than a second exception.

The answer is a page of our own, not the router's error page: the router is
what failed.  With TPSGI\_DEBUG set it carries the error itself, trace and all,
for the same reason the error pages add one; without, it says nothing a visitor
could use to map the installation.

The worker retires once it has answered, on a server that offers
psgix.harakiri, which Starman does.  A router that died while it compiled
leaves its file in %INC as a failure, and every later require of it in this
process says only "Attempt to reload ... aborted" -- so a load that failed
once, to a race or a lock, would otherwise fail for every request the worker
ever serves.  A fresh worker tries again from nothing.

## respond($env) = PSGI response

Answer one request: from a route when one matches, by running a CGI when the
file under `www/` is executable, and otherwise by serving the file.  A path
that a route matches, with a method that no route of it has, gets
notallowed().

## mangle\_filename($path) = STRING

$path, lowercased on the systems whose filesystems ignore case.

## parse\_ranges($env) = LIST

The byte ranges of the request's Range header, as ARRAY references of start
and end.  An end that the header leaves out is undef.  If-Range without Range
asks for the whole file.

## appears\_executable($path) = BOOL

Whether $path is a CGI to run rather than a file to serve: it is executable,
and it has no extension or one of `cgi`, `sh`, `exe`, `pl`, `php` and `py`.

## route($route, $env, %request) = PSGI response

Run the callback of $route, which TPSGI::Router::match() returned, with the
query that extract\_query() builds.  In CGI mode, which `x-tpsgi-env` asks
for, the query is not built, and the callback gets the request as %ENV
instead.  respond() calls route(), with %request holding `fullpath`, `path`,
`start`, `last_fetch`, `deflate`, `domain` and `port`.

## extract\_query($path, $route, $env) = HASHREF

The query a route's callback is given: the query string, then the POST body,
then the path parameters of $route and the operation's `x-tpsgi-data`, each
over the last.  First TPSGI::Router::validate() checks the request against the
operation.  A request that fails gets unsupported() for a 415 and badrequest()
for a 400, and the reasons go to the log at the debug level.

## cgi($env, $fullpath, $file\_actual, $last\_fetch) = PSGI response

Run $file\_actual as a CGI.  Read until we are done with headers, then pass off
the filehandle to PSGI for streaming.

## stream\_raw\_cgi($cgi)

Run the perl file $cgi in this process, as a CGI: its STDIN is the request body,
and what it prints goes to the client.  The worker exits when it is done.

Use when you just have a .cgi file you want to run without pipe-open.
XXX this is extraordinarily unsafe, inefficient and kills workers.
But sometimes you have to bite the bullet and do this to migrate stuff effectively.

## stream\_raw\_psgi($response, $query)

Write the PSGI $response straight to the client's socket, close it, then run
the callbacks that add\_post\_close\_callback() queued.  route() does this when
there are any.  The worker exits when it is done.

## stream\_raw\_http($query, $last\_fetch, $to\_fork, $callback, $error\_handler)

Answer with a 200 whose headers and body a forked child prints: $to\_fork runs
in the child with the client's socket selected, and then $error\_handler, when
there is one.  Once the child exits and the socket is closed, $callback runs.
The worker exits when it is done.

## extract\_headers($fh, $last\_fetch)

Extract the headers from a filehandle.  Set the 'Last Modified' header appropriately based on the output of \`stat\` on the filehandle.

Returns a code and parsed headers hash.  Code will be 304 if the file hasn't changed since $last\_fetch, otherwise will be the code in the parsed headers.

## static($fullpath, $path, $start, $streaming, $last\_fetch) = PSGI response

Answer with the static render of $path that save\_render() made, headers and
all, or forbidden() when there is none.

## get\_config() = HASH

TPSGI::Startup::get\_config(): `~/.tpsgi.ini`, over the defaults.

## checkpoint($query, $name)

Mark the time as $name, for the Server-Timing header that
build\_server\_timing() makes.

## build\_server\_timing($query) = STRING

A Server-Timing header value: how long each checkpoint() took after the one
before it, and the total since the request started.

## add\_post\_close\_callback()

Add a thing to do after closing stdout; useful for housekeeping that doesn't need to hold up pageload.

## signal\_restart\_parent()

Instruct tPSGI to reload after closing stdout.

## save\_render($path, $extension, $body)

Save a static render of the page.
Good to queue after closing stdout.

Passed file extension slapped on the end of the path.
You can then serve them as statics with an appropriately done try\_files block in nginx.

## invalidate\_render($path, $extension)

Remove an existing static render of a path.

## invalidate\_renders($extension)

Remove all existing static renders with the provided extension.
Useful when it's not easy to figure out what to re-render due to including templates in other templates, etc.

## watch\_for\_changes(@dirs)

TPSGI::Startup::watch\_for\_changes(), which watches the .pm files under @dirs for
autoreload.  A function, not a method.

## add\_watch($path, $callback, %options)

Add an arbitrary file or directory to the inotify watchlist, along with a
callback to run when it changes.  Returns the inotify watch descriptor.

The callback is invoked as:

```
$callback->( $tpsgi, $change );
```

...where $change is a HASH reference describing what happened:

```perl
path    => full path of the thing which changed
watched => the path the watch was registered against
events  => ARRAY reference of event names, e.g. [ 'MODIFY' ]
name    => entry within a watched directory, if the watch was on a directory
wd      => inotify watch descriptor
mask    => raw inotify event mask
```

Which makes the common case - blowing away a static render because the thing it
was generated from changed - look like:

```perl
$tpsgi->add_watch( "data/posts.json", sub {
    my ( $tpsgi, $change ) = @_;
    $tpsgi->invalidate_renders('html');
});
```

%options are passed through to TPSGI::Startup::add\_watch, so you may also pass
'events' (defaults to CREATE, MODIFY, DELETE and MOVE) and 'key' (an explicit
dedupe key for the callback).

Some caveats worth knowing about:

- Watches live in the inotify instance tarbaby sets up before forking, and
are therefore shared by every worker.  Whichever worker notices a change first
consumes it for all of them, so register the same callbacks in every worker
(declare them in your router module, which every worker loads) and make sure
they're safe to run in any worker.
- Changes are only noticed when a request comes in, since nothing is
sitting in a select loop over the inotify FD.  Renders are invalidated promptly
in practice, but not instantly.
- Watching a directory rather than a single file is more robust, as
watching a file which is later replaced wholesale (the usual write-tempfile-then-
rename dance) only survives because we re-establish the watch afterwards.  If
the file is deleted and not immediately recreated, the watch is gone for good.

## remove\_watch($path)

Drop a path, and any callbacks registered against it, from the watchlist.

## handle\_changes

Drain the inotify queue, running the callbacks registered for whatever changed,
and restart tPSGI if any of the relevant libdir files changed (assuming
autoreload is on).  Powers both the autorestart feature and app-registered
watches.

## restart\_if\_changes

Deprecated alias for handle\_changes().

# CONFIGURATION

Obeys ~/.tpsgi.ini -- this is what will control all the custom aspects mentioned below:

```perl
verbose     : Whether to print all log messages or not
custom_log  : Custom location for default (rotated) log
routers     : Router module(s), separate with comma.  Relative to TPSGI install dir.
indices     : Dirindex files.  In addition to index.html, index.htm, index.cgi
loggers     : Logger module(s), separate with comma.  Each is a Log::Dispatch::Output class.  tPSGI loads it by name, so it can live beside a router
auth        : Authentication module
domain      : Domain name of the application, used by things like service files
basedir     : Directory you want to chdir into on startup. Relative to TPSGI install dir.  Default '.'
user        : Who to run as
http_user   : Who's proxying this application (used for statics)
autoreload  : Whether or not to automatically reload the application when library files change. Default 0.
```

You can run bin/tpsgi-config to get any config value needed by scripts.

We wrap starman with a custom script, `bin/tarbaby` that implements Plack::Loader::Reload far less dangerously.
It only reloads the code relevant to tPSGI and your application itself.
All the CPAN deps should be updated out-of-band and the service manually restarted, as this is far more fraught.

# CUSTOM ROUTING

tPSGI requires each router module, and routes requests by the OpenAPI 3
document that each one exports as `%openapi`.  A router can also export
`%aliases`, `%watches` and `generic_route()`.

```perl
package My::Routes;
use Mojo::JSON ();

our %openapi = (
    openapi => '3.0.3',
    info    => { title => 'My routes', version => '1' },
    paths   => {
        '/sitemap/{map}.xml' => {
            get => {
                'x-tpsgi-callback' => \&sitemap,
                'x-myapp-nomap'    => Mojo::JSON::true,
                parameters         => [
                    {
                        name     => 'map',
                        in       => 'path',
                        required => Mojo::JSON::true,
                        schema   => { type => 'integer' },
                    },
                ],
                responses => { 200 => { description => 'One page of the sitemap' } },
            },
        },
        '/lib/{module+}' => {
            get => {
                'x-tpsgi-callback' => 'My::Routes::manual',
                'x-tpsgi-data'     => { section => 'manual' },
                parameters         => [
                    {
                        name     => 'module+',
                        in       => 'path',
                        required => Mojo::JSON::true,
                        schema   => { type => 'string' },
                    },
                ],
                responses => { 200 => { description => 'The manual of a module' } },
            },
        },
    },
);
```

The document is Perl data.  A boolean in it must be `Mojo::JSON::true` or
`Mojo::JSON::false`.  `\1` and `builtin::true` fail the check against the
OpenAPI schema.  Write the full name: `use 5.040` imports `builtin::true` as
`true`, and that wins over an imported `Mojo::JSON::true`.

new() dies when a document is not valid, so a broken router fails as it loads,
and not at the first request.  A router that still defines `@routes` and no
`%openapi` dies the same way.

## Templates

Each key of `paths` is a template.  `{name}` matches any text up to the next
slash, and one segment can hold several variables and literal text, as in
`{map}.xml`.  `{name+}` matches the rest of the path, slashes and all, and it
must be the whole last segment.  Its parameter is named `name+`, and the query
gives its value as `name`.  Any other character matches only itself.  No
variable matches a newline.

When more than one template matches, the most concrete one wins.  Literal
segments win over segments with variables, segments that mix text and
variables win over a lone `{name}`, and `{name+}` comes last.  Then the
template with more literal characters wins, and then the one that sorts first.
[TPSGI::Router](https://metacpan.org/pod/TPSGI%3A%3ARouter) says this in full.

A path that a template matches, with a method that no matching template has,
gets a 405 with an `Allow` header.  HEAD uses the `get` operation when there
is no `head` one.

## Operations

The `x-tpsgi-` keys of an operation are tPSGI's:

```perl
x-tpsgi-callback  The sub that answers the request: a CODE reference, or
                  the fully qualified name of a sub.  Required.
x-tpsgi-data      A HASH, which is merged over the query.
x-tpsgi-env       True for CGI mode: the callback gets the request as a
                  CGI %ENV, and no query is built.
```

Any other `x-` key is the application's.  The callback finds the whole
operation in `$query->{dispatcher}`, and the template that matched in
`$query->{route_template}`.

## Validation

Before the callback runs, tPSGI checks the request against the operation's
`parameters` and `requestBody`.  Values are coerced to their schema, so an
integer arrives as a number.  A request that fails gets a 400, and the reasons
go to the log at the debug level, not into the page.  The 400 is also the
answer to a query key that the operation does not declare, when the operation
declares a query parameter or a request body.  A form body is as strict as the
`additionalProperties` of its schema.  A body whose media type is not among
the `content` of the `requestBody` gets a 415.

## Callbacks

A callback is passed the TPSGI object and the query, which means you can do:

```perl
sub route {
    my ($self, $query) = @_;
    $self->INFO("whatever");
    $self->ERROR("eeee");
    $self->DEBUG("blah");

    # From the query string, the POST body, the path or x-tpsgi-data, in
    # that order: a later one wins.
    my $param = $query->{param};

    my %headers = ...;

    return [200, \%headers, ["Hello world"]]
}
```

# WATCHING FILES FOR CHANGES

tPSGI already watches your library directories with inotify so that it can reload itself when your
code changes.  Your application can put arbitrary files and directories onto that same watchlist,
along with a callback to run when they change.  The usual reason to want this is throwing away a
static render because the thing it was generated from changed underneath it.

Routing modules declare these the same way they declare routes:

```perl
our %watches = (
    # A bare coderef is the common case: run this when the path changes.
    'data/posts.json' => sub {
        my ($tpsgi, $change) = @_;
        $tpsgi->invalidate_renders('html');
    },

    # Or spell it out if you want to be picky about which events you care about.
    'www/assets' => {
        callback => \&asset_changed,
        events   => [qw{CREATE MOVE}],
    },
);
```

...or register them at runtime with `$tpsgi->add_watch($path, $callback, %options)`, and drop them
again with `$tpsgi->remove_watch($path)`.

Callbacks are passed the TPSGI object and a hashref describing what happened:

```perl
sub asset_changed {
    my ($tpsgi, $change) = @_;

    $change->{path};    # full path of the thing which changed
    $change->{watched}; # the path the watch was registered against
    $change->{events};  # arrayref of event names, e.g. ['MODIFY']

    $tpsgi->invalidate_render($change->{path}, 'html');
}
```

A few things worth knowing:

- Watches are shared by every worker, so whichever worker notices a change first consumes it for all
of them.  Declare your watches in your routing module (which every worker loads) rather than from
inside a single route, and make the callbacks safe to run in any worker.
- Nothing sits in a select loop over the inotify descriptor, so changes are noticed when the next
request comes in.  Prompt, but not instant.
- Watching the containing directory is more robust than watching a single file.  Watches on files
which get replaced wholesale (write a tempfile, rename over the target) are re-established
afterwards, but a file which is deleted and not recreated takes its watch with it.

# CUSTOM AUTHENTICATION HANDLING

The (optional) Authentication handler can be passed, and look like so:

```perl
package Auth::Handler;

# Is user who they say they are
sub authenticate {
    my (%auth_payload) = @_;
    ...
    return ($session_cookie);
}

# is the user authorized to do $thing
sub authorized {
    my ($user, $priv) = @_;
    ...
    return 1 || 0;
}

# Available ACLs
sub acls {
    ...
    return %acls;
}

# Dump acls for user
sub acls_for_user {
    my $user = shift;
    ...
    return %acls;
}

# What is the user for this session token
sub user_for_session {
    my $session = shift;
    ...
    return $user;
}
```

In the event that auth or route handlers are found, these events will be noted in the startup log.

# LOGGING

By default we have two log handlers...which you can augment with your own, based on Log::Dispatch.

The first default is to print ERROR and worse to the STDOUT of the PSGI server.
The other is to emit INFO or better to logs/tpsgi.log

Pass your own dispatch subclasses and watch it go whir.

# SERVICE CONFIGURATION

Proper operation of this as a production service requires some things:

1. You have a user which has this repository as their home directory.
2. You run the shell script, tpsgi.sh in service/ to run this as a service.
3. You set the username and the domain name of the service in .tpsgi.ini
4. You set your PATH appropriately to pick up on things like custom perls in a .bashrc
5. You set the group of your reverse proxy application in .tpsgi.ini (the http\_user variable)

run service/tpsgi.sh as root and you should be set supposing the above is true.

In general the operation is like so:

1. nginx (or whatever) looks for a sock file owned $USER:$WEB\_GROUP, and reverse proxies to this
2. tpsgi is actively listening on this sock file.

Generally you'll just run bin/build\_service and then systemctl start $domain.
It's configured to start as root, then drop privs thanks to Net::Server's capabilities inherited in starman.

## Secrets the application needs

An application often needs a key or a password that has no business living in
its own checkout, where it would go into every backup alongside whatever it
protects.  bin/build\_service makes one and puts it in systemd's credential
store; the unit imports it and service/tpsgi.sh hands it on.

You do not have to do anything for this.  build\_service writes
`/etc/credstore.encrypted/tpsgi-vault` if it is not there already, encrypted
with `systemd-creds --with-key=auto`: sealed to the TPM when the machine has a
usable one, and to the host key when it does not.  It says which you got, since
that is the difference between a stolen disk being useless and a stolen disk
being a stolen key.  An existing key is left alone.

systemd decrypts it into a ramdisk at `/run/credentials/$service` that only this
service can read.  Nothing breaks if it is not there: `ImportCredential=` is
quiet about a credential that does not exist, so an installation whose
application wants no secrets starts normally.

The workers are chrooted into the application directory and that ramdisk is
outside it, so service/tpsgi.sh reads the credential before the chroot happens
and exports it -- `tpsgi-vault` becomes `TPSGI_VAULT_KEY`.  An application taking
one is expected to read it out of its environment as it starts and delete it
there and then, so that nothing it forks afterwards inherits it.

It is named for tPSGI rather than for whatever is being served, because this is
tPSGI's unit and one service is one application in one directory.

The key is not backed up and cannot be recovered.  That is deliberate: it lives
and dies with the machine, so that it is never sitting in the same backup as the
data it protects.  Rebuilding the host means whatever was sealed under it is
gone and gets stored again.

# BUGS

Please report any bugs or feature requests on the bugtracker website
[https://github.com/Troglodyne-Internet-Widgets/tPSGI/issues](https://github.com/Troglodyne-Internet-Widgets/tPSGI/issues)

When submitting a bug or request, please include a test-file or a
patch to an existing test-file that illustrates the bug or desired
feature.

# AUTHORS

Current Maintainers:

- George S. Baugh <george@troglodyne.net>

# CONTRIBUTORS

- Andy Baugh <andy@troglodyne.net>
- troglodyne-bot <morpheus@troglodyne.net>

# COPYRIGHT AND LICENSE

Copyright (c) 2026 Troglodyne LLC

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:
The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.
THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
