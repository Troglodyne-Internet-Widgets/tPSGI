use strict;
use warnings;

use ExtUtils::MakeMaker;

WriteMakefile(
    VERSION   => '0.01',
    META_MERGE        => {
    "meta-spec" => { version => 2 },
        resources => {
            repository => {
                type => 'git',
                url  => 'git@github.com:Troglodyne-Internet-Widgets/tpsgi.git',
                web  => 'https://github.com/Troglodyne-Internet-Widgets/tpsgi',
            },
        },
    },
    PREREQ_PM => {
        "Carp::Always" => "0",
        "CGI::Emulate::PSGI" => "0",
        "Config::Simple" => "0",
        "Cwd" => "0",
        "Data::Dumper" => "0",
        "DateTime::Format::HTTP" => "0",
        "File::Find" => "0",
        "File::Path" => "0",
        "File::Touch" => "0",
        "FindBin::libs" => "0",
        "IO::Compress::Gzip" => "0",
        "List::Util" => "0",
        "Log::Dispatch" => "0",
        "Log::Dispatch::FileRotate" => "0",
        "Log::Dispatch::Screen" => "0",
        "Mojo::File" => "0",
        "Plack::MIME" => "0",
        "POSIX" => "0",
        "Sys::Hostname" => "0",
        "UUID" => "0",
        "Devel::NYTProf" => "0",
        "Starman" => "0",
    },
    test => {TESTS => 't/*.t'}
);
