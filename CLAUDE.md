# CLAUDE.md — tPSGI

## Project overview

tPSGI is a PSGI server wrapper built around Starman. It bridges legacy CGI/mod_perl
applications onto PSGI, and powers tCMS. Key features: static file serving, CGI
execution, custom route dispatch, gzip compression, byte-range streaming, hot-reload
via inotify.

## Architecture

Two processes:

- **`bin/tarbaby`** — master Starman process. Uses only `TPSGI::Startup` (minimal
  deps). Sets up inotify watches for hot-reload before forking workers.
- **`bin/tpsgi`** — PSGI app file loaded by each Starman worker. Creates a `TPSGI`
  object per request, dispatches to routes or static files.

Key modules:

- **`lib/TPSGI.pm`** — main library. Route dispatch, static serving, CGI execution,
  multipart range responses, gzip, post-close callbacks.
- **`lib/TPSGI/Startup.pm`** — lightweight module for `get_config()` and
  `watch_for_changes()`. Loaded only by tarbaby to avoid restart on TPSGI.pm changes.

## Routes

Routes live in flat paired arrays: `[pattern1, handler1, pattern2, handler2, ...]`.
Patterns at **even** indices, handler hashrefs at **odd** indices. Exact match is
tried first; then regex match.

When writing code that iterates the route array, always restrict to even indices:

```perl
my @pat_idx = grep { !($_ % 2) } 0 .. $#$r;
```

## Configuration

`~/.tpsgi.ini` in `[default]` block (Config::Simple key=value format). Fields:
`verbose`, `custom_log`, `routers`, `loggers`, `auth`, `domain`, `user`,
`http_user`, `autoreload`, `basedir`, `binds`, `tpsgi_dir`.

## Running tests

Tests require the local `perl5` lib in scope. Either:

```bash
eval $(perl -I$HOME/perl5/lib/perl5 -Mlocal::lib)
prove -Ilib t/
```

Or directly:

```bash
PERLBASE=$HOME/perl5/lib/perl5
perl -I$PERLBASE -I$PERLBASE/x86_64-linux-gnu-thread-multi -Ilib t/01-startup.t
```

Tests use `t/lib/TPSGITestStubs.pm` to stub missing CPAN deps. Stubs prefer real
modules when loadable; they only activate when the real module is absent.

## Key patterns

- `TPSGI->new()` validates the running user matches `options{user}`. Tests bypass
  this by blessing a raw hashref: `bless { user => ..., ... }, 'TPSGI'`.
- `bin/tarbaby` must NOT `use TPSGI` directly — only `use TPSGI::Startup`. This
  keeps the master process isolated from TPSGI.pm changes.
- NYTProf: only load via `require Devel::NYTProf` guarded by `if ($ENV{NYTPROF})`.
  Never set `$ENV{NYTPROF}` unconditionally before `require`.
- Multipart range terminator: `"\n--$CHUNK_SEP--\n"` — the `--` is literal, not
  an escape. In Perl double-quoted strings `\-` is a backslash, not a dash.
- `HTTP::Body` must be declared with `use HTTP::Body` — it does not load
  transitively from Plack in all configurations.
- `parse_ranges` and `extract_query`: never use `my $x = expr if cond` — the
  variable retains its value from previous calls when the condition is false
  (Perl UB). Always use an explicit `if`/`else` or ternary.
- `stream_raw_psgi`: iterate `@{$response->[2]}` for the body — not just `[0]`.

## Commit conventions

Plain English imperative: "Fix multipart boundary", "Add test suite", etc.
No ticket prefix. Keep under 72 chars.
