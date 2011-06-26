package Carton::CLI;
use strict;
use warnings;

use Carton;
use Carton::Util;

use Cwd;
use Config;
use Getopt::Long;
use Term::ANSIColor qw(colored);

use Carton::Tree;

our $Colors = {
    SUCCESS => 'green',
    INFO    => 'cyan',
    ERROR   => 'red',
};

sub new {
    my $class = shift;
    bless {
        path  => 'local',
        color => 1,
        verbose => 0,
        carton => Carton->new,
    }, $class;
}

sub carton { $_[0]->{carton} }

sub work_file {
    my($self, $file) = @_;
    return "$self->{work_dir}/$file";
}

sub run {
    my($self, @args) = @_;

    $self->{work_dir} = $ENV{PERL_CARTON_HOME} || (Cwd::cwd() . "/.carton");
    mkdir $self->{work_dir}, 0777 unless -e $self->{work_dir};

    local @ARGV = @args;
    my @commands;
    my $p = Getopt::Long::Parser->new(
        config => [ "no_ignore_case", "pass_through" ],
    );
    $p->getoptions(
        "h|help"    => sub { unshift @commands, 'help' },
        "v|version" => sub { unshift @commands, 'version' },
        "color!"    => \$self->{color},
        "verbose!"  => \$self->{verbose},
    );

    push @commands, @ARGV;

    my $cmd = shift @commands || 'usage';
    my $call = $self->can("cmd_$cmd");

    if ($call) {
        $self->$call(@commands);
    } else {
        die "Could not find command '$cmd'\n";
    }
}

sub commands {
    my $self = shift;

    no strict 'refs';
    map { s/^cmd_//; $_ }
        grep /^cmd_(.*)/, sort keys %{__PACKAGE__."::"};
}

sub cmd_usage {
    my $self = shift;
    print <<HELP;
Usage: carton <command>

where <command> is one of:
  @{[ join ", ", $self->commands ]}

Run carton -h <command> for help.
HELP
}

sub parse_options {
    my($self, $args, @spec) = @_;
    Getopt::Long::GetOptionsFromArray($args, @spec);
}

sub print {
    my($self, $msg, $type) = @_;
    $msg = colored $msg, $Colors->{$type} if $type && $self->{color};
    print $msg;
}

sub check {
    my($self, $msg) = @_;
    $self->print("✓ ", "SUCCESS");
    $self->print($msg . "\n");
}

sub error {
    my($self, $msg) = @_;
    $self->print($msg, "ERROR");
    exit(1);
}

sub cmd_help {
    my $self = shift;
    my $module = "Carton::Doc::" . ($_[0] ? ucfirst $_[0] : "Carton");
    system "perldoc", $module;
}

sub cmd_version {
    print "carton $Carton::VERSION\n";
}

sub cmd_install {
    my($self, @args) = @_;

    $self->parse_options(\@args, "p|path=s", \$self->{path}, "deployment!" => \$self->{deployment});
    $self->carton->configure_cpanm(path => $self->{path});

    if (@args) {
        $self->print("Installing modules from the command line\n");
        $self->carton->install_modules(\@args);
        $self->carton->update_packages($self->lock_file);
    } elsif (my $file = $self->has_build_file) {
        $self->print("Installing modules using $file\n");
        $self->carton->install_from_build_file($file);
        $self->carton->update_packages($self->lock_file);
    } elsif (-e $self->lock_file) {
        $self->print("Installing modules using carton.lock\n");
        $self->carton->install_from_lock($self->lock_data, $self->mirror_file);
    } else {
        $self->error("Can't locate build file or carton.lock\n");
    }

    $self->print("Complete! Modules were installed into $self->{path}\n", "SUCCESS");
}

sub mirror_file {
    my $self = shift;
    return $self->work_file("02packages.details.txt");
}

sub has_build_file {
    my $self = shift;

    # deployment mode ignores build files and only uses carton.lock
    return if $self->{deployment};

    my $file = (grep -e, qw( Build.PL Makefile.PL ))[0]
        or return;

    if ($self->mtime($file) > $self->mtime($self->lock_file)) {
        return $file;
    }

    return;
}

sub mtime {
    my($self, $file) = @_;
    return (stat($file))[9] || 0;
}

*cmd_list = \&cmd_show;

sub cmd_show {
    my($self, @args) = @_;

    my $tree_mode;
    $self->parse_options(\@args, "tree!" => \$tree_mode);

    my $lock = $self->lock_data
        or $self->error("Can't find carton.lock: Run `carton install` to rebuild the spec file.\n");


    if ($tree_mode) {
        $self->carton->walk_down_tree($lock, sub {
            my($module, $depth) = @_;
            print "  " x $depth;
            print "$module->{dist}\n";
        });
    } else {
        for my $module (values %{$lock->{modules} || {}}) {
            printf "$module->{dist}\n";
        }
    }
}

sub cmd_check {
    my $self = shift;

    $self->check_cpanm_version;
    # check carton.lock and extlib?
}

sub check_cpanm_version {
    my $self = shift;

    my $version = (`$self->{cpanm} --version` =~ /version (\S+)/)[0];
    unless ($version && $version >= 1.5) {
        $self->error("carton needs cpanm version >= 1.5. You have " . ($version || "(not installed)") . "\n");
    }
    $self->check("You have cpanm $version");
}

sub cmd_update {
    # "cleanly" update distributions in extlib
    # rebuild the tree, update modules with DFS
}

sub cmd_exec {
    # setup lib::core::only, -L env, put extlib/bin into PATH and exec script
}

sub lock_data {
    my $self = shift;
    $self->{lock} || do {
        Carton::Util::parse_json($self->lock_file);
    };
}

sub lock_file {
    my $self = shift;
    return 'carton.lock';
}


1;
