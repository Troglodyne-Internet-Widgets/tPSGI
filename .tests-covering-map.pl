#!/usr/bin/env perl
use 5.040;
use warnings FATAL => 'all';
use re '/aasx';

=head1 NAME

.tests-covering-map.pl - which tests reach the files that no test loads, for
tests-covering

=head1 DESCRIPTION

git-hooks/pre-commit asks tests-covering which tests a commit can break.
tests-covering follows the Perl that each test loads, and asks this map about
every other file in the diff.  See "THE MAP" in L<Perl::Tests::Covering>.

The map answers C<q{}>, which is C<NO_TESTS>, for the files of a distribution
that C<prove -l t/> never reads:

=over

=item Documentation

Markdown, POD in F<.pod> files outside F<lib/>, F<Changes>, F<LICENSE> and
F<README>.

=item The build and the release

F<dist.ini>, F<weaver.ini>, F<prereqs.yml> and F<prereqs.json>, F<MANIFEST.SKIP>
and F<cpanfile>.  C<dzil> reads them, and C<dzil test> checks what they build.

=item The tools and the hooks

The C<perltidy> and C<perlcritic> configuration and the files that it reads,
F<.mailmap>, F<.gitignore>, F<.gitattributes>, this map, F<git-hooks/> and
F<.github/>.

=item The author tests

F<xt/>, which the hooks do not run.

=item The programs that no test runs

F<call.pl>, the shell scripts in F<bin/> and F<service/>, and the unit template
in F<service/>.

=back

Anything else, it leaves unexplained, and the hook then runs every test.  A
file that a test reads without loading it, such as a template or a fixture,
wants a rule here that names the tests that read it.

=cut

# Read by the tools, by dzil or by people, and by no test.
my %NO_TESTS = map { $_ => 1 } qw{
  Changes LICENSE README README.md
  dist.ini weaver.ini prereqs.yml prereqs.json MANIFEST.SKIP cpanfile
  .perltidyrc .perlcriticrc .perlcriticrc.compat .pod_stopwords .preferred_modules.ini .preferred_binaries.ini
  .mailmap .gitignore .gitattributes .tests-covering-map.pl
  call.pl bin/build_service bin/scan_log_for_warnings.sh
};

return sub {
    my ($path) = @_;

    return q{} if $NO_TESTS{$path};
    return q{} if $path =~ m{\A(?:git-hooks|[.]github|xt)/};
    return q{} if $path =~ m{[.]md\z};
    return q{} if $path =~ m{[.]pod\z} && $path !~ m{\Alib/};

    # The service's shell script and unit template, which no test runs.
    return q{} if $path =~ m{\Aservice/};

    return;
};
