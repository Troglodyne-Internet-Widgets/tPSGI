# tPSGI

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

## Configuration

Obeys ~/.tpsgi.ini -- this is what will control all the custom aspects mentioned below:

    verbose     : Whether to print all log messages or not
    custom_log  : Custom location for default (rotated) log
    routers     : Router module(s), separate with comma.  Relative to TPSGI install dir.
    indices     : Dirindex files.  In addition to index.html, index.htm, index.cgi
    loggers     : Logger module(s), separate with comma
    auth        : Authentication module
    domain      : Domain name of the application, used by things like service files
    basedir     : Directory you want to chdir into on startup. Relative to TPSGI install dir.  Default '.'
    user        : Who to run as
    http_user   : Who's proxying this application (used for statics)
    autoreload  : Whether or not to automatically reload the application when library files change. Default 0.

You can run bin/tpsgi-config to get any config value needed by scripts.

We wrap starman with a custom script, `bin/tarbaby` that implements Plack::Loader::Reload far less dangerously.
It only reloads the code relevant to tPSGI and your application itself.
All the CPAN deps should be updated out-of-band and the service manually restarted, as this is far more fraught.

## Custom routing

All passed routing modules will be required, and combined to form a routing table so you have an analogue to rewrite rules.

Routing Modules look like so:
```
our @routes = (
    '/foo/(\w+)/save' => {
        method    => 'GET',
        callbacks => { # Run these subroutines to execute the appropriate handler given the content-type.  Expects normal PSGI output.
            'text/html'        => \&render,
            'application/json' => \&dump,
        },
        noindex   => 0, # Explicitly exclude this in robots.txt
        nomap     => 0, # Don't put this in the sitemap
        acls      => ['admin'], # Route requires both authentication by auth handler and the auth'd user to have the provided ACLs.
        data      => { baz => 'throb' }, # Arbitrary data to inject into the GET/POST data hashref
        captures  => ['name','parameter'], # Name parameters of the capture groups in the route key.  Suppose we want /foo/don/keys here.
        static    => 1, # Whether we can save a static render of this
        invalidates => ['/foo/(\w+)'], # Static renders which are invalidated by this route returning a successful response code.
    },
    ...
);
```
Note that this is an array, as we want this to preserve order. Fat commas are used to hint that this is in fact a tuple.

Router callbacks are passed the TPSGI object and the raw query, which means you can do:

    sub route {
        my ($self, $query) = @_;
        $self->INFO("whatever");
        $self->ERROR("eeee");
        $self->DEBUG("blah");

        # Either from the GET or POST data, POST is preferred when both are present.
        my $param = $query->{param};

        my %headers = ...;

        return [200, \%headers, ["Hello world"]]
    }

## Custom Authentication handling

The (optional) Authentication handler can be passed, and look like so:

```
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

## Logging

By default we have two log handlers...which you can augment with your own, based on Log::Dispatch.

The first default is to print ERROR and worse to the STDOUT of the PSGI server.
The other is to emit INFO or better to logs/tpsgi.log

Pass your own dispatch subclasses and watch it go whir.

## Service configuration

Proper operation of this as a production service requires some things:

0. You have a user which has this reposity as their home directory.
1. You run the shell script, tpsgi.sh in service/ to run this as a service.
2. You set the username and the domain name of the service in .tpsgi.ini
3. You set your PATH appropriately to pick up on things like custom perls in a .bashrc
4. You set the group of your reverse proxy application in .tpsgi.ini (the http\_user variable)

run service/tpsgi.sh as root and you should be set supposing the above is true.

In general the operation is like so:

1. nginx (or whatever) looks for a sock file owned $USER:$WEB\_GROUP, and reverse proxies to this
2. tpsgi is actively listening on this sock file.

Generally you'll just run bin/build\_service and then systemctl start $domain.
It's configured to start as root, then drop privs thanks to Net::Server's capabilities inherited in starman.

