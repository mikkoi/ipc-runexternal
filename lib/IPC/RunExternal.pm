## no critic (ControlStructures::ProhibitDeepNests)
## no critic (ValuesAndExpressions::ProhibitMagicNumbers)

package IPC::RunExternal;

use strict;
use warnings;
use 5.010000;

# ABSTRACT: Execute an external command conveniently by hiding the details of IPC::Open3.

# VERSION: generated by DZP::OurPkgVersion

=pod

=for stopwords API mailmap Readonly committer undef committers MSWin Unices OpenVMS runexternal

=for stopwords Mikko Koivunalho

=encoding utf8

=head1 SYNOPSIS

    use IPC::RunExternal;

    my $external_command = 'ls -r /'; # Any normal Shell command line
    my $stdin = q{}; # STDIN for the command. Must be an initialised string, e.g. q{}.
    my $timeout = 60; # Maximum number of seconds before forced termination.
    my %parameter_tags = (print_progress_indicator => 1);
    # Parameter tags:
    # print_progress_indicator [1/0]. Output something on the terminal every second during
        # the execution, to tell user something is still going on.
    # progress_indicator_char [*], What to print, default is '#'.
    # execute_every_second [&], instead of printing the same everytime,
        # execute a function. The first parameters to this function is the number of seconds passed.

    my ($exit_code, $stdout, $stderr, $allout);
    ($exit_code, $stdout, $stderr, $allout)
            = runexternal($external_command, $stdin, $timeout, \%parameter_tags);

    # Parameter tags opened:
    ($exit_code, $stdout, $stderr, $allout)
            = runexternal($external_command, $stdin, $timeout, { progress_indicator_char => q{#} });

    # Print `date` at every 10 seconds during execution
    my $print_date_function = sub {
        my $secs_run = shift;
        if($secs_run % 10 == 0) {
            print `/bin/date`;
        }
    };
    ($exit_code, $stdout, $stderr, $allout) = runexternal($external_command, $stdin, $timeout,
            { execute_every_second => $print_date_function
            });


=head1 DESCRIPTION

IPC::RunExternal is for executing external operating system programs
more conveniently than with C<``> or C<system()>,
and without all the hassle of IPC::Open3.

IPC::RunExternal allows:

=over 8

=item 1) Capture F<stdout> and F<stderr> in scalar variables.

=item 2) Capture both F<stdout> and F<stderr> in one scalar variable, in the correct order.

=item 3) Use timeout to break the execution of a program running too long.

=item 4) Keep user happy by printing something (e.g. '.' or '#') every second.

=item 5) Not happy with simply printing something? Then execute your own code (function) at every second while the program is running.

=back


=head1 STATUS

This package is currently being developed so changes in the API and functionality are possible.

=head1 DEPENDENCIES

Requires Perl version 5.6.2.


=cut

use English '-no_match_vars';
use Carp 'croak';
use IPC::Open3;
use IO::Select; # for select
use Symbol 'gensym'; # for gensym

use Exporter 'import';
our @EXPORT_OK   = qw(runexternal);
our @EXPORT      = qw(runexternal); ## no critic (Modules::ProhibitAutomaticExportation)
our %EXPORT_TAGS = ( all => [ qw(runexternal) ] );

use autodie;

# CONSTANTS for this module
my $TRUE = 1;
my $FALSE = 0;
my $EMPTY_STR = q{};

my $DEFAULT_PRINT_PROGRESS_INDICATOR = $FALSE;
my $DEFAULT_PROGRESS_INDICATOR_CHARACTER = q{.};
my $DEFAULT_EXECUTE_EVERY_SECOND_ROUTINE_POINTER = $FALSE;
my $EXIT_STATUS_OK = 1;
my $EXIT_STATUS_TIMEOUT = 0;
my $EXIT_STATUS_FAILED = -1;
my $SIGKILL = 9;

# GLOBALS
# No global variables



=head1 EXPORT

Exports routine runexternal().

=head1 INCOMPATIBILITIES

Working in MSWin not guaranteed, might also not work in other Unices / OpenVMS / other systems. Tested only in Linux.
Depends mostly on IPC::Open3 working in the system.

=head1 SUBROUTINES/METHODS

=head2 runexternal

Run an external (operating system) command.

=over 8

=item Parameters:

=over 8

=item 1. command, a system executable.

=item 2. input (F<stdin>), for the command, must be an initialised string,
    if no input, string should be empty.

=item 3. timeout, 0 (no timeout) or greater.

=item 4. parameter tags (a hash)

=over 8

=item print_progress_indicator: 1/0 (TRUE/FALSE), default FALSE

=item progress_indicator_char: default "."; printed every second.

=item execute_every_second: parameter to a function, executed every second.

=back

=back

=item Return values (an array of four items):

=over 8

=item 1. exit_status, an integer,

=over 8

=item 1 = OK

=item 0 = timeout (process killed). "Timeout" added to $output_error and $output_all.

=item -1 = couldn't execute (IPC:Open3 failed, other reason). Reason (given by shell) in $output_error.

=back

=item 2. $output_std (what the command returned)

=item 3. $output_error (what the command returned)

=item 4. $output_all: $output_std and $output_error mixed in order of occurrence.

=back

=back

=head1 SEE ALSO

=over 8

=item L<IPC::Run>

=item L<System::Command>

=item L<IPC::Open3>

=back

=cut

sub runexternal { ## no critic (Subroutines::ProhibitExcessComplexity)

    # Parameters
    my ($command, $input, $timeout, $parameter_tags) = @_;

    if(!defined $command) {
        croak('Parameter \'command\' is not initialised!');
    }
    if(!defined $input) {
        croak('Parameter \'input\' is not initialised!');
    }
    if($timeout < 0) {
        croak('Parameter \'timeout\' is not valid!');
    }

    my $print_progress_indicator = $DEFAULT_PRINT_PROGRESS_INDICATOR;
    if(exists $parameter_tags->{'print_progress_indicator'}) {
        if($parameter_tags->{'print_progress_indicator'} == $FALSE ||
                $parameter_tags->{'print_progress_indicator'} == $TRUE) {
            $print_progress_indicator = $parameter_tags->{'print_progress_indicator'};
        }
        else {
            croak('Parameter \'print_progress_indicator\' is not valid (must be 1/0)!');
        }
    }

    my $progress_indicator_char = $DEFAULT_PROGRESS_INDICATOR_CHARACTER;
    if(exists $parameter_tags->{'progress_indicator_char'}) {
        $progress_indicator_char = $parameter_tags->{'progress_indicator_char'};
    }

    my $execute_every_second = $DEFAULT_EXECUTE_EVERY_SECOND_ROUTINE_POINTER;
    if(exists $parameter_tags->{'execute_every_second'}) {
        if(ref($parameter_tags->{'execute_every_second'}) eq 'CODE') {
            $execute_every_second = $parameter_tags->{'execute_every_second'};
        }
        else {
            croak('Parameter execute_every_second is not a code reference!');
        }
    }

    # Variables
    my $command_exit_status = $EXIT_STATUS_OK;
    my $output_std = $EMPTY_STR;
    my $output_error = $EMPTY_STR;
    my $output_all = $EMPTY_STR;

    # Validity check
    if(
            $command ne $EMPTY_STR
            #&& defined($input)
            && $timeout >= 0
    )
    {
        local $OUTPUT_AUTOFLUSH = $TRUE; # Equals to var $|. Flushes always after writing.
        my ($infh,$outfh,$errfh); # these are the FHs for our child
        $errfh = gensym(); # we create a symbol for the errfh
                           # because open3 will not do that for us
        my $pid;
        # Read Perl::Critic::Policy::ErrorHandling::RequireCheckingReturnValueOfEval
        # for an evil eval weakness and a dasdardly difficult eval handling.
        my $eval_ok = 1;
        eval {
            $pid = open3($infh, $outfh, $errfh, $command);
            # To cover the possiblity that an operation may correctly return a
            # false value, end the block with "1":
            1;
        } or do {
            $eval_ok = 0;
        };
        if($eval_ok) {
            print {$infh} $input; ## no critic (InputOutput::RequireCheckedSyscalls)
            close $infh;
            my $sel = IO::Select->new(); # create a select object to notify
                                         # us on reads on our FHs
            $sel->add($outfh, $errfh);   # add the FHs we're interested in
            my $out_handles_open = 2;
            ## no critic (ControlStructures::ProhibitCStyleForLoops)
            for(my $slept_secs = -1; $out_handles_open > 0 && $slept_secs < $timeout; $slept_secs++) {
                while(my @ready = $sel->can_read(1)) { # read ready, timeout after 1 second.
                    foreach my $fh (@ready) {
                        my $line = <$fh>;        # read one line from this fh
                        if( !(defined $line) ){   # EOF on this FH
                            $sel->remove($fh);   # remove it from the list
                            $out_handles_open -= 1;
                            next;                # and go handle the next FH
                        }
                        if($fh == $outfh) {      # if we read from the outfh
                            $output_std .= $line;
                            $output_all .= $line;
                        } elsif($fh == $errfh) { # do the same for errfh
                            $output_error .= $line;
                            $output_all .= $line;
                        } else {                 # we read from something else?!?!
                            croak "Shouldn't be here!\n";
                        }
                    }
                }
                if($timeout == 0) {
                    # No timeout, so we lower the counter by one to keep it forever under 0.
                    # Only the closing of the output handles ($out_handles_open == 0) can break the loop
                    $slept_secs--;
                }
                if($print_progress_indicator == $TRUE && $out_handles_open > 0) {
                    print {*STDOUT} $progress_indicator_char; ## no critic (InputOutput::RequireCheckedSyscalls)
                }
                if($execute_every_second && $out_handles_open > 0) {
                    &{$execute_every_second}($slept_secs);
                }
            }
            # It is safe to kill in all circumstances.
            # Anyway, we must reap the child process.
            my $killed = kill $SIGKILL, $pid;
            my $command_return_status = $CHILD_ERROR >> 8;
            if($out_handles_open > 0) {
                $output_error .= 'Timeout';
                $output_all .= 'Timeout';
                $command_exit_status = $EXIT_STATUS_TIMEOUT;
            }
        }
        else {
            # open3 failed!
            $output_error .= 'Could not run command';
            $output_all .= 'Could not run command';
            $command_exit_status = $EXIT_STATUS_FAILED;
        }
    }
    else {
        # Parameter check
        $output_error .= 'Invalid parameters';
        $output_all .= 'Invalid parameters';
        $command_exit_status = $EXIT_STATUS_FAILED;
    }

    return ($command_exit_status, $output_std, $output_error, $output_all);
}

1;

