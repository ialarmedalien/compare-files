package MyLogger;

use strict;
use Cwd;
use Log::Log4perl qw(get_logger :levels);
use Log::Log4perl::Level;

use Exporter;
use vars qw(@ISA @EXPORT);
@ISA = qw(Exporter); # Log::Log4perl);
@EXPORT = qw( $ALL $TRACE $DEBUG $INFO $WARN $ERROR $FATAL $OFF );
use Carp;
use Data::Dumper;
my $logger;

#BEGIN {
#
#}

my $basic =
'class   = Log::Log4perl::Layout::PatternLayout
pattern = %p %M[%L]%n%m%n%n
time_pat = %d [%p] %M %l%n%m%n%n


## Log to STDERR
log4perl.appender.StdErr        = Log::Log4perl::Appender::Screen
log4perl.appender.StdErr.mode   = append
log4perl.appender.StdErr.layout = ${class}
log4perl.appender.StdErr.layout.ConversionPattern = ${pattern}
log4perl.appender.StdErr.stderr = 1

## Log to STDOUT (terminal)
log4perl.appender.Term        = Log::Log4perl::Appender::Screen
log4perl.appender.Term.mode   = append
log4perl.appender.Term.layout = ${class}
log4perl.appender.Term.layout.ConversionPattern = ${pattern}
log4perl.appender.Term.stderr = 0

log4perl.oneMessagePerAppender = 1
';

my $extras = {
	'stderr_thresh' => 'log4perl.appender.StdErr.Threshold = FATAL',
	'stdout_thresh' => 'log4perl.appender.Term.Threshold = FATAL',
	'debug' => 'log4perl.logger = DEBUG, StdErr',
	'info' => 'log4perl.logger = INFO, StdErr',
	'warn' => 'log4perl.logger = WARN, StdErr',
	'fatal' => 'log4perl.logger = FATAL, StdErr',
};

my $config = {
	'galaxy' => $basic . "\n" . $extras->{stderr_thresh} ."\n". $extras->{fatal},
	'verbose' => $basic . "\n" . $extras->{info},
	'standard' => $basic . "\n" . $extras->{warn},
	'debug' => $basic . "\n" . $extras->{debug},
};

INIT {
	my $init = 'standard';
	if ( $ENV{GO_VERBOSE} )
	{	$init = 'debug';
	}

#	print STDERR "Running INIT code...\n";
	Log::Log4perl::init( \$config->{$init} );
	$logger = get_logger();

	$SIG{__WARN__} = sub {
		local $Log::Log4perl::caller_depth = $Log::Log4perl::caller_depth + 1;
		if (@_)
		{	$logger->warn("Oh no!\n@_");
		}
#		Log::Log4perl::WARN( @_ );
	};

	$SIG{__DIE__} = sub {
		if($^S) {
	# We're in an eval {} and don't want log
	# this message but catch it later
			return;
		}
		local $Log::Log4perl::caller_depth = $Log::Log4perl::caller_depth + 1;
		$logger->logdie(@_);
#		Log::Log4perl::LOGDIE( @_ );
	};


}

sub init_with_config_str {
	my $conf = shift;
	Log::Log4perl::init( \$conf );
}

sub init_with_config {
	my $conf = shift;
	if (! $config->{$conf})
	{	$logger->error("$conf: config not found!");
	}
	else
	{	Log::Log4perl::init( \$config->{$conf} );
	}
}

1;
