# tPSGI

Yet another abstraction layer atop the already towering and excellent one that is `starman`.

```
tpsgi --router Trog::Routes::HTML --conf conf/config.ini --logger Log::Dispatch::Mine --auth Trog::Auth ... [starman args]
```

A PSGI server built to migrate old mod\_perl/apache stacks onto psgi, and that powers tCMS.

Will execute any executable file (chmod +x) in www/ as CGI, and otherwise host any static file therein.

All passed routing modules will be required, and combined to form a routing table so you have an analogue to rewrite rules.

Routing Modules look like so:
```
our %routes = (
    '/foo/(\w+)/(\w+)' => {
       method => 'GET',
       callback => &sub, # Run this subroutine to execute the route.  Expects normal PSGI output.
       noindex => 0, # Explicitly exclude this in robots.txt
       nomap   => 0, # Don't put this in the sitemap
       auth    => 0, # Route requires authentication by auth handler
       data    => { baz => 'throb' }, # Arbitrary data to inject into the GET/POST data hashref
       captures => ['name','parameter'], # Name parameters of the capture groups in the route key.  Suppose we want /foo/don/keys here.
    },
    ...
);
```

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

Set the env var DEBUG=1 to have both emit all message levels.

Pass your own dispatch subclasses and watch it go whir.
