#!/usr/bin/perl -w

=head1 NAME

compare-obo-files.pl - compare two OBO files

=head1 SYNOPSIS

 compare-obo-files.pl --file_1 old_gene_ontology.obo --file_2 gene_ontology.obo
 -m html -o results.html

=head1 DESCRIPTION

Compares two OBO files and records the differences between them, including:

* new terms

* term merges

* term obsoletions

* changes to term content, such as addition, removal or editing of features like
synonyms, xrefs, comments, def, etc..

* changes in relationships between terms

At present, only term differences are recorded in detail, although this could
be extended to other stanza types in an ontology file. The comparison is based
on creating hashes of term stanza data, mainly because hashes are more tractable
than objects.

=head2 Input parameters

=head3 Required

=over

=item -o || --output /path/to/file_name

output file for results

If the output format is specified as 'html', the suffix '.html' will be added
to the file name if it is not already present.

=back

=head3 Configuration options

=over

=item Comparing two existing files

Enter the two files using the following syntax:

 -f1 /path/to/file_name  -f2 /path/to/file_2_name

where f1 is the "old" ontology file and f2 is the "new" file

=back

=head3 Optional switches

=over

=item -m || --mode I<html>

HTML mode, i.e. format the output as HTML (the default is a plain text file)

=item -l || --level I<medium>

level of detail to report about term changes; options are short (s), medium (m) or long (l)

=item -v || --verbose

prints various messages during the execution of the script

=back

=cut

use strict;
use Data::Dumper;
$Data::Dumper::Sortkeys = 1;

use lib "$ENV{HOME}/compare-files";
use MyLogger;
use Template;
use DateTime::Format::Strptime;

##
my $defaults = {
#	f => 'go/ontology/editors/gene_ontology_write.obo',
#	go_root => $ENV{GO_CVSROOT} || "",
	mode => 'text',
	level => 'm',
	## location of templates; paths should be separated by a colon
	inc_path => "templates:$ENV{HOME}/compare-files/templates/",
};

my $html_defaults = {
	## base dir for URLs in html
	install_dir => 'http://www.geneontology.org/',
	## browser links
	term_url_prefix => 'http://amigo.geneontology.org/cgi-bin/amigo/term_details?term=',
	term_url_suffix => '',
};

my @ordered_attribs = qw(id
is_anonymous
name
namespace
alt_id
def
comment
subset
synonym
xref
is_a
intersection_of
union_of
disjoint_from
relationship
is_obsolete
replaced_by
consider);

my @single_attribs = qw(name namespace is_obsolete def comment is_anonymous );
my $logger;

run_script($defaults, \@ARGV);

exit(0);

sub run_script {

my $options = parse_options(@_);

my $t_args = {
	INCLUDE_PATH => $options->{inc_path},
};

if ($options->{mode} eq 'html')
{	$t_args->{POST_CHOMP} = 1;
}

my $tt = Template->new($t_args) || $logger->logdie("$Template::ERROR");

my $data;
my $output;
my $parser;

my @tags_to_parse = qw(name is_a relationship subset);
my $tags_regex = qr/^(name|is_a|relationship|subset):/;

if ($options->{level})
{	$output->{level} = $options->{level};
}

## pull in the ontology data from each file.

foreach my $f ('f1', 'f2')
{
#	$logger->warn("Ready to read in $f!");
#	read in everything up to the first stanza (i.e. the header info)
	open(FH, "<" . $options->{$f}) or die("Could not open " . $options->{$f} . "! $!");

	# remove and parse the header
	local $/ = "\n[";

	my $header = <FH>;
	my @f_data;
	my $slash = rindex $options->{$f}, "/";
	if ($slash > -1)
	{	push @f_data, substr $options->{$f}, ++$slash;
	}
	else
	{	push @f_data, $options->{$f};
	}

	if ($header =~ /^data-version: (.*)$/m)
	{	push @f_data, "data version: $1";
	}
	if ($header =~ /^date: (.*)$/m)
	{	push @f_data, "date: $1";
		$output->{$f . "_date"} = $1;
	}
	if ($header =~ /cvs version: \$Revision:\s*(\S+)/m)
	{	push @f_data, "CVS revision: " . $1;
		$output->{$f . "_cvs"} = $1;
	}
	if ($header =~ /^default-namespace: (.*)$/m)
	{	$output->{$f . '_default_namespace'} = $1;
	}
	if (@f_data)
	{	$output->{$f . '_file_data'} =  join("; ", @f_data);
	}
	else
	{	$output->{$f . '_file_data'} = "unknown";
	}

	$logger->info("Parsed $f header; starting body");
#	$logger->debug("header: " . Dumper($data->{$f}{header}));
	my @all_lines;
	## we're pulling in chunks of text, separated by \n[
	while (<FH>)
	{	if (/^(\S+)\]\s*.*?^id:\s*(\S+)/sm)
		{	# store the data as a tag-value hash indexed by stanza type and id
			# data->{$file}{$stanza_type}{$stanza_id}
			my $type = $1;
			my $id = $2;
			my @lines = map { $_ =~ s/ ! .*//; $_ } grep { /^[^!]/ && /\w/ } split("\n", $_);
			$lines[0] = "[" . $lines[0];
			$data->{$f."_lines"}{$type}{$id} = [ sort @lines ];

			# save alt_ids
			if ($type eq 'Term' && grep { /^alt_id:/ } @lines)
			{	my @arr = map { $_ =~ s/alt_id:\s*//; $_ } grep { /^alt_id:/ } @lines;
				# check for dodgy alt ids...
				foreach (@arr)
				{	if ($data->{$f . "_alt_ids"}{$_} )
					{	$logger->info("$id: alt_id $_ is already assigned to " . $data->{$f . "_alt_ids"}{$_});
					}
					else
					{	$data->{$f . "_alt_ids"}{$_} = $id;
					}
				}
			}

			# extract the interesting data
			# skip obsoletes
			my $obs_flag;
			if ($type eq 'Term')
			{	## get stuff for stats
				$data->{$f . "_stats"}{total}++;
				if ($_ =~ /^is_obsolete: true/m)
				{	$data->{$f."_stats"}{obs}++;
					$data->{$f."_obs_terms"}{$id}++;
					$obs_flag++;
				}
				else
				{	## get the term's namespace...
					my $ns = 'unknown';
					if ($_ =~ /^namespace: (.*?)\s*$/m)
					{	$ns = $1;
					}
					else
					{	if ($output->{$f . '_default_namespace'})
						{	#$logger->warn("default_namespace: " . $parser->default_namespace);
							$ns = $output->{$f . '_default_namespace'};
						}
					}
					$data->{$f . "_stats"}{by_ns}{$ns}{total}++;
					if ($_ =~ /^def: /m)
					{	$data->{$f."_stats"}{by_ns}{$ns}{def}++;
						$data->{$f."_stats"}{def_not_obs}++;
					}
				}
			}
			next if $obs_flag;

=cut
			## if we're doing a subset analysis, collect the data we'll need
			## the OBO parser will then create a graph from this data
			if ($options->{subset})
			{	if ($type eq 'Term')
				{	## is this still necessary?
					push @all_lines, ( "[Term]", "id: $id");
					my @arr = grep { /$tags_regex/ } @lines;
					push @all_lines, @arr, "";
				}
				elsif ($type eq 'Typedef')
				{	#push @lines, ("[Typedef]", "id: $id");
					#foreach my $tag (keys %{$data->{$f . "_hash"}{$1}{$2}})
					#{	map { push @lines, $tag . ": " . $_; } @{$data->{$f . "_hash"}{$1}{$2}{$tag}};
					#}
					push @all_lines, @lines, "";
				}
			}
=cut
		}
		else
		{	$logger->warn("Couldn't understand data!\n$_\n");
		}
	}
	close FH;
	$logger->info("Finished parsing $f body");
}

## ANALYSIS STAGE! ##

# ignore these tags when we're comparing hashes
my @tags_to_ignore = qw(id);

## check! Should we do this or not?
if ($options->{subset})
{	@tags_to_ignore = qw(id is_a relationship);
}
## end check!

my $ignore_regex = '(' . join("|", @tags_to_ignore) . ')';
$ignore_regex = qr/$ignore_regex/;
$logger->info("Read data; starting term analysis");

## ok, check through the terms and compare 'em
## go through all the terms in f1 and add them to the stats

foreach my $t (keys %{$data->{f1_lines}{Term}})
{
	## check for term in f2
	## see if it is an alt ID (i.e. it has been merged)
	## if not, it may have been lost
	if (! $data->{f2_lines}{Term}{$t})
	{	# check it hasn't been merged
		if ($data->{f2_alt_ids}{$t})
		{
			# the term was merged. N'mind!
			$output->{f1_to_f2_merge}{$t} = $data->{f2_alt_ids}{$t};
			## make sure we have the data about the term in f1 and f2
			if (! $data->{f1_hash}{Term}{$t})
			{	$data->{f1_hash}{Term}{$t} = block_to_hash( join("\n", @{$data->{f1_lines}{Term}{$t}} ) );
			}
			if (! $data->{f2_hash}{Term}{ $data->{f2_alt_ids}{$t} })
			{	$data->{f2_hash}{Term}{ $data->{f2_alt_ids}{$t} } = block_to_hash( join("\n", @{$data->{f2_lines}{Term}{ $data->{f2_alt_ids}{$t} }} ) );
			}

		}
		else
		{	$logger->info("$t is only in file 1");
			$output->{f1_only}{$t}++;

			if (! $data->{f1_hash}{Term}{$t})
			{	$data->{f1_hash}{'Term'}{$t} = block_to_hash( join("\n", @{$data->{f1_lines}{Term}{$t}} ) );
			}


		}
	}
}

foreach my $t (sort keys %{$data->{f2_lines}{Term}})
#foreach my $t (sort keys %{$data->{f2_hash}{Term}})
{	#if (! $data->{f1_hash}{Term}{$t})
	if (! $data->{f1_lines}{Term}{$t})
	{	# check it hasn't been de-merged
		if ($data->{f1_alt_ids}{$t})
		{	# erk! it was an alt id... what's going on?!
			$logger->warn("$t was an alt id for " . $data->{f1_alt_ids}{$t} . " but it has been de-merged!");
			$output->{f2_to_f1_merge}{$t} = $data->{f1_alt_ids}{$t};

			if (! $data->{f1_hash}{Term}{ $data->{f1_alt_ids}{$t} })
			{	$data->{f1_hash}{Term}{ $data->{f1_alt_ids}{$t} } = block_to_hash( join("\n", @{$data->{f1_lines}{Term}{ $data->{f1_alt_ids}{$t} }} ) );
			}
			if (! $data->{f2_hash}{Term}{$t})
			{	$data->{f2_hash}{Term}{$t} = block_to_hash( join("\n", @{$data->{f2_lines}{Term}{$t}} ) );
			}


		}
		else
		{	$output->{f2_only}{$t}++;
			if (! $data->{f2_hash}{Term}{$t})
			{	$data->{f2_hash}{'Term'}{$t} = block_to_hash( join("\n", @{$data->{f2_lines}{Term}{$t}} ) );
			}

		}
	}
## the term is in f1 and f2. let's see if there are any differences
	else
	{	# quickly compare the arrays, see if they are the same
		## fx_str is composed of the sorted tag-value pairs
		next if join("\0", @{$data->{f1_lines}{Term}{$t}}) eq join("\0", @{$data->{f2_lines}{Term}{$t}});

		foreach my $f qw(f1 f2)
		{	if (! $data->{$f . "_hash"}{'Term'}{$t})
			{	$data->{$f . "_hash"}{'Term'}{$t} = block_to_hash( join("\n", @{$data->{$f . "_lines"}{Term}{$t}} ) );
			}
		}

		## the arrays are different. Let's see just how different they are...
		my $r = compare_hashes( f1 => $data->{f1_hash}{Term}{$t}, f2 => $data->{f2_hash}{Term}{$t}, to_ignore => $ignore_regex );
		if ($r)
		{	$data->{diffs}{Term}{both}{$t} = $r;

			$output->{term_changes}{$t} = $r;
			foreach (keys %$r)
			{	$data->{diffs}{Term}{all_tags_used}{$_}{$t}++;
			}
		}
	}
}

my @attribs = grep { exists $data->{diffs}{Term}{all_tags_used}{$_} && $_ ne 'id' } @ordered_attribs;

$output->{term_change_attribs} = [ @attribs ] if @attribs;

$logger->info("Checked for new and lost terms");

foreach my $a qw(name namespace)
{	if ($data->{diffs}{Term}{all_tags_used}{$a})
	{	map { $output->{$a . "_change" }{$_}++ } keys %{$data->{diffs}{Term}{all_tags_used}{$a}};
	}
}

if ($data->{diffs}{Term}{all_tags_used}{is_obsolete})
{	foreach my $t (keys %{$data->{diffs}{Term}{all_tags_used}{is_obsolete}})
	{
		if ($data->{f2_obs_terms}{$t})
		#if ($data->{f2_hash}{Term}{$t}{is_obsolete})
		{	$output->{f2_obsoletes}{$t}++;
			$logger->debug("added $t to f2 obsoletes");
			if (! $data->{f2_hash}{Term}{$t})
			{	$data->{f2_hash}{Term}{$t} = block_to_hash( join("\n", @{$data->{f2_lines}{Term}{$t}} ) );
			}

		}
		else
		{	$output->{f1_obsoletes}{$t}++;
			$logger->warn("added $t to f1 obsoletes");
		}
	}
}

$logger->debug("output - obsoletes: " . Dumper($output->{f2_obsoletes}) . "\n\nf1 obs: " . Dumper($output->{f1_obsoletes}) . "\n");

$logger->info("Sorting and storing data");
$output->{f1_term_lines} = $data->{f1_lines}{Term};
$output->{f2_term_lines} = $data->{f2_lines}{Term};
$output->{f1_term_hash} = $data->{f1_hash}{Term};
$output->{f2_term_hash} = $data->{f2_hash}{Term};
$output = generate_stats($output, $data);
$output = compare_other_stanzas($output, $data);

foreach (@single_attribs)
{	$output->{single_value_attribs}{$_}++;
}

$output->{show_term_changes} = 1;
$output->{install_dir} = $options->{install_dir};

#$logger->warn("output keys: " . join("; ", sort keys %$output) . "");
$logger->info("Printing results!");

## add urls for making web links
if ($options->{mode} eq 'html')
{	foreach (keys %$html_defaults)
	{	$output->{$_} = $html_defaults->{$_};
	}
}

# create_rss( options => $options, output => $output, tt => $tt );
output_data( options => $options, output => $output, tt => $tt );

}

sub create_rss {
	my %args = (@_);
	my $tt = $args{tt};

	my $files = {
		new => $ENV{HOME} . '/go/www/rss/new_term.rss',
		obsolete => $ENV{HOME} . '/go/www/rss/obs_term.rss',
	};
	my $do_this;

	## make sure that we need to create the new files
	if ($args{output}->{f2_only} && scalar keys %{$args{output}->{f2_only}} > 0)
	{	$do_this->{new}++;
	}
	if ($args{output}->{f2_obsoletes}  && scalar keys %{$args{output}->{f2_obsoletes}} > 0)
	{	$do_this->{obsolete}++;
	}

	if (! keys %$do_this)
	{	return;
	}

	my $parser = DateTime::Format::Strptime->new(pattern => "%d:%m:%Y %H:%M");
	my $date;
	## get the date from the header of f2
	if ($args{output}->{f2_date})
	{
		$date = $parser->parse_datetime( $args{output}->{f2_date} );
	}
	else
	{	$date = DateTime->now();
	}


	## get our current time and work out what a month ago would be

	$args{output}->{full_date} = $date->strftime("%a, %d %b %Y %H:%M:%S %z"),
	my $old = $date->clone->subtract( months => 1 );

#	print STDERR "old: " . $old . "\n";

	$parser = DateTime::Format::Strptime->new(pattern => "%a, %d %b %Y %H:%M:%S %z");


	## create the new term rss
	## pull in the existing rss file
	foreach my $x qw(new obsolete)
	{	next unless $do_this->{$x};
		my $old_data;
		if (-e $files->{$x})
		{	local( $/, *NEW ) ;
			open( NEW, $files->{$x} ) or die "Could not open " . $files->{$x} . ": $!";
			my $text = <NEW>;
			my @items = split("<item>", $text);
			my @ok;
			my @guids = ();
			$items[-1] =~ s/\s*<\/channel>\s*<\/rss>//sm;

			foreach (@items)
			{	# we're looking at an item
				if (/\<\/item>/s)
				{	$_ =~ s/(\<\/item>).*?/$1\n/s;
					if (/<pubDate>(.*?)<\/pubDate>/)
					{	my $dt = $parser->parse_datetime( $1 );
						if ($dt < $old)
						{	next;
						}
					}

					if (/<guid>(.*?)<\/guid>/m)
					{	if (grep { $_ eq $1 } @guids)
						{	## got this already
						}
						else
						{	push @ok, "<item>" . $_;
							push @guids, $1;
						}
					}
				}
			}
			if (@ok)
			{	$old_data = join "\n", @ok;
			}
			close( NEW );
		}

		$tt->process(
			$x . '_term_rss.tmpl',
			{ %{$args{output}}, old_data => $old_data },
			$files->{$x},
			)
		|| die $tt->error(), "\n";
	}

}

sub output_data {
	my %args = (@_);
	my $tt = $args{tt};

	$tt->process(
		$args{options}->{mode} . '_report.tmpl',
		$args{output},
		$args{options}->{output})
    || die $tt->error(), "\n";

}

sub compare_other_stanzas {
	my $output = shift;
	my $d = shift;
	my $ignore = qw/id/;
	## compare the other types of stanza
	foreach my $type (keys %{$d->{f1_hash}})
	{	next if $type eq 'Term';
		foreach my $t (keys %{$d->{f1_hash}{$type}})
		{	if (! $d->{f2_hash}{$type} || ! $d->{f2_hash}{$type}{$t})
			{	$logger->warn("$type $t is only in file 1");
				$output->{other}{f1_only}{$type}{$t}++;
				if ($d->{f1_hash}{$type}{$t}{name})
				{	$output->{other}{f1_only}{$type}{$t} = { name => $d->{f1_hash}{$type}{$t}{name}[0] };
				}
			}
		}
		foreach my $t (keys %{$d->{f2_hash}{$type}})
		{	if (! $d->{f1_hash}{$type}|| ! $d->{f1_hash}{$type}{$t})
			{	$output->{other}{f2_only}{$type}{$t}++;
				if ($d->{f2_hash}{$type}{$t}{name})
				{	$output->{other}{f2_only}{$type}{$t} = { name => $d->{f2_hash}{$type}{$t}{name}[0] };
				}
			}
			else
			{	# quickly compare the arrays, see if they are the same
				my $f1_str = join("\0", map {
					join("\0", @{$d->{f1_hash}{$type}{$t}{$_}})
				} sort keys %{$d->{f1_hash}{$type}{$t}});

				my $f2_str = join("\0", map {
					join("\0", @{$d->{f2_hash}{$type}{$t}{$_}})
				} sort keys %{$d->{f2_hash}{$type}{$t}});
				next if $f1_str eq $f2_str;

				my $r = compare_hashes( f1 => $d->{f1_hash}{$type}{$t}, f2 => $d->{f2_hash}{$type}{$t}, to_ignore => $ignore );
				if ($r)
				{	$output->{other}{both}{$type}{$t} = $r;
					if (! $output->{other}{both}{$type}{$t}{name} && ( $d->{f2_hash}{$type}{$t}{name} || $d->{f1_hash}{$type}{$t}{name}) )
					{	$output->{other}{both}{$type}{$t}{name} = $d->{f2_hash}{$type}{$t}{name}[0] || $d->{f1_hash}{$type}{$t}{name}[0];
					}
		#			foreach (keys %$r)
		#			{	$output->{diffs}{$type}{all_tags_used}{$_}++;
		#			}
				}
			}
		}
	}
	return $output;
}


sub generate_stats {
	my $vars = shift;
	my $d = shift;

#	$logger->warn("f1 stats: " . Dumper($d->{f1_stats}) . "\nf2 stats: " . Dumper($d->{f2_stats}) . "\n");

	$vars->{f2_stats} = $d->{f2_stats};
	$vars->{f1_stats} = $d->{f1_stats};
	map { $vars->{ontology_list}{$_}++ } (keys %{$vars->{f1_stats}{by_ns}}, keys %{$vars->{f2_stats}{by_ns}});

	foreach my $f qw( f1 f2 )
	{	foreach my $o (keys %{$vars->{$f . "_stats"}{by_ns}})
		{	## we have def => n terms defined
			## total => total number of terms
			if (! $vars->{$f. "_stats"}{by_ns}{$o}{def})
			{	$vars->{$f. "_stats"}{by_ns}{$o}{def} = 0;
				$vars->{$f. "_stats"}{by_ns}{$o}{def_percent} = 0;
			}
			else
			{	$vars->{$f . "_stats"}{by_ns}{$o}{def_percent} = sprintf("%.1f", $vars->{$f. "_stats"}{by_ns}{$o}{def} / $vars->{$f. "_stats"}{by_ns}{$o}{total} * 100);
			}
		}
		foreach my $x qw(obs def_not_obs)
		{	if (! $vars->{$f."_stats"}{$x})
			{	$vars->{$f."_stats"}{$x} = 0;
				$vars->{$f."_stats"}{$x . "_percent"} = 0;
			}
			else
			{	$vars->{$f."_stats"}{$x . "_percent"} = sprintf("%.1f", $vars->{$f. "_stats"}{$x} / $vars->{$f. "_stats"}{total} * 100);
			}
		}
	}

	foreach my $x qw(obs def_not_obs total)
	{	$vars->{delta}{$x} = $vars->{f2_stats}{$x} - $vars->{f1_stats}{$x};
		$vars->{delta}{$x . "_percent"} = sprintf("%.1f", $vars->{delta}{$x} / $vars->{f1_stats}{$x} * 100);
	}

	foreach my $x qw( f1 f2 )
	{	$vars->{$x."_stats"}{extant} = $vars->{$x."_stats"}{total} - $vars->{$x."_stats"}{obs};
		$vars->{$x."_stats"}{def_extant_percent} = sprintf("%.1f", $vars->{$x."_stats"}{def_not_obs} / $vars->{$x."_stats"}{extant} * 100);
	}

	foreach my $o (keys %{$vars->{ontology_list}})
	{	if ($vars->{f1_stats}{by_ns}{$o} && $vars->{f2_stats}{by_ns}{$o})
		{	$vars->{delta}{$o} = $vars->{f2_stats}{by_ns}{$o}{total} - $vars->{f1_stats}{by_ns}{$o}{total};
		}
	}

#	foreach my $x qw(f1_stats f2_stats delta)
#	{	print STDERR "$x: " . Dumper( $vars->{$x} )."\n";
#	}


	return $vars;
}


sub get_term_data {
	my %args = (@_);
	my $d = $args{data};
	my $output = $args{output};
	my $t = $args{term};
	my $to_get = $args{data_to_get};
	my $f = $args{f_data} || 'f2';

#	$logger->warn("args: " . join("\n", map { $_ . ": " . Dumper($args{$_}) } qw(term data_to_get f_data)) ."");


#	$logger->warn("data: " . Dumper($d->{$f . "_hash"}{Term}{$t}) . "\n");

#	if (! $d->{$f . "_hash"}{Term}{$t} && ! $args{f_data})
	if (! $d->{$f . "_lines"}{Term}{$t} && ! $args{f_data})
	{	## we weren't explicitly looking for the data from f2...
		$logger->warn("Couldn't find data for $t in $f; trying again...");
		if ($f eq 'f2')
		{	$f = 'f1';
		}
		else
		{	$f = 'f2';
		}
		get_term_data(%args, f_data => $f);
		return;
	}

	foreach my $x (@$to_get)
	{	next if $output->{$f}{$t}{$x};
		my @arr = grep { /^$x:/ } @{$d->{$f . "_lines"}{Term}{$t}};
		next unless @arr;
		if (grep { /^$x$/ } @single_attribs)
		{	($output->{$f}{$t}{$x} = $arr[0]) =~ s/$x:\s*//;
		}
		else
		{	$output->{$f}{$t}{$x} = [ map { s/$x:\s*//; $_ } @arr ];
		}

		if ($x eq 'anc')
		{	if (grep { /^is_obsolete/ } @{$d->{$f . "_lines"}{Term}{$t}})
			{	$output->{$f}{$t}{anc} = ['obsolete'];
			}
			else
			{	if ($d->{$f}{trimmed})
				{	my $stts = $d->{$f}{trimmed}->statements_in_ix_by_node_id('ontology_links', $t);
					if (@$stts)
					{	my %parent_h;
						map { $parent_h{$_->target->id} = 1 } @$stts;
						$output->{$f}{$t}{anc} = [ sort keys %parent_h ];
					}
				}
			}
		}
		if ($x eq 'namespace' && grep { /^is_obsolete/ } @{$d->{$f . "_lines"}{Term}{$t}})
		{	$output->{$f}{$t}{$x} = 'obsolete';
		}
	}


#	$logger->warn("wanted " . join(", ", @$to_get) . " for $t from $f; returning: " . Dumper($output->{$f}{$t}) . "");
}


=head2 Script methods

=head2 block_to_hash

input:  a multi-line block of text (preferably an OBO format stanza!)
output: lines in the array split up by ": " and put into a hash
        of the form key-[array of values]

Directly does what could otherwise be accomplished by block_to_sorted_array
and tag_val_arr_to_hash

=cut

sub block_to_hash {
	my $block = shift;

	my $arr;
	foreach ( split( "\n", $block ) )
	{	next unless /\S/;
		next if /^(id: \S+|\[|\S+\])\s*$/;
		$_ =~ s/^(.+?:)\s*(.+)\s*^\\!\s.*$/$1 $2/;
		$_ =~ s/\s*$//;
		## look for a " that isn't escaped
		if ($_ =~ /^def: *\"(.+)(?<!\\)\" *\[(.+)\]/)
		{	my ($def, $xref) = ($1, $2);
			push @$arr, ( "def: $def", "def_xref: $xref" );
		}
		else
		{	push @$arr, $_;
		}
	}
	return undef unless $arr && @$arr;
	my $h;
	foreach (@$arr)
	{	my ($k, $v) = split(": ", $_, 2);
		if (! $k || ! $v)
		{	#$logger->warn("line: $_");
		}
		else
		{	push @{$h->{$k}}, $v;
		}
	}

	map { $h->{$_} = [ sort @{$h->{$_}} ] } keys %$h;

	return $h;
}


=head2 compare_hashes

input:  hash containing
        f1 => $f1_term_data
        f2 => $f2_term_data
        to_ignore => regexp for hash keys to ignore

output: hash of differences in the form
        {hash key}{ f1 => [ values unique to f1 ]
                    f2 => [ values unique to f2 ] }

=cut

sub compare_hashes {
	my %args = (@_);
	my $f1 = $args{f1};
	my $f2 = $args{f2};
	my $ignore = $args{to_ignore};

	my $results;
	my $all_values;
	foreach my $p (keys %$f1)
	{	# skip these guys
		next if $p =~ /^$ignore$/;
		if (! $f2->{$p})
		{	$results->{$p}{f1} += scalar @{$f1->{$p}};
			$all_values->{$p}{f1} = $f1->{$p};
		}
		else
		{	# find the same / different values
			my @v1 = values %$f1;
			my @v2 = values %$f2;

			my %count;
			foreach my $e (@{$f1->{$p}})
			{	$count{$e}++;
			}
			foreach my $e (@{$f2->{$p}})
			{	$count{$e} += 10;
			}

			foreach my $e (keys %count) {
				next if $count{$e} == 11;
				if ($count{$e} == 1)
				{	$results->{$p}{f1}++;
					push @{$all_values->{$p}{f1}}, $e;
				}
				elsif ($count{$e} == 10)
				{	$results->{$p}{f2}++;
					push @{$all_values->{$p}{f2}}, $e;
				}
			}
		}
	}
	foreach (keys %$f2)
	{	if (! $f1->{$_})
		{	$results->{$_}{f2} += scalar @{$f2->{$_}};
			$all_values->{$_}{f2} = $f2->{$_};
		}
	}

#	return { summary => $results, with_values => $all_values };
	return $all_values;
}

# parse the options from the command line
sub parse_options {

	my ($opt, $args) = @_;
	my $errs;

	while (@$args && $args->[0] =~ /^\-/) {
		my $o = shift @$args;
		if ($o eq '-f1' || $o eq '--file_1' || $o eq '--file_one') {
			if (@$args && $args->[0] !~ /^\-/)
			{	$opt->{f1} = shift @$args;
			}
		}
		elsif ($o eq '-f2' || $o eq '--file_2' || $o eq '--file_two') {
			if (@$args && $args->[0] !~ /^\-/)
			{	$opt->{f2} = shift @$args;
			}
		}
=cut
		## VITAL if d1 and d2 are being used
		elsif ($o eq '-f' || $o eq '--file' || $o eq '--file') {
			if (@$args && $args->[0] !~ /^\-/)
			{	$opt->{f} = shift @$args;
			}
		}
		elsif ($o eq '-d1' || $o eq '--date_1' || $o eq '--date_one') {
			if (@$args && $args->[0] !~ /^\-/)
			{	$opt->{d1} = shift @$args;
				$opt->{d1} =~ s/(^["']|["']$)//g;
			}
		}
		elsif ($o eq '-d2' || $o eq '--date_2' || $o eq '--date_two') {
			if (@$args && $args->[0] !~ /^\-/)
			{	$opt->{d2} = shift @$args;
				$opt->{d2} =~ s/(^["']|["']$)//g;
			}
		}
=cut
		elsif ($o eq '-o' || $o eq '--output') {
			if (@$args && $args->[0] !~ /^\-/)
			{	$opt->{output} = shift @$args;
			}
		}
		elsif ($o eq '-m' || $o eq '--mode') {
			if (@$args && $args->[0] !~ /^\-/)
			{	my $m = shift @$args;
				$opt->{mode} = lc($m);
			}
		}
		elsif ($o eq '-h' || $o eq '--help') {
			system("perldoc", $0);
			exit(0);
		}
		elsif ($o eq '-v' || $o eq '--verbose') {
			$opt->{verbose} = 1;
		}
		elsif ($o eq '-l' || $o eq '--level') {
			if (@$args && $args->[0] !~ /^\-/)
			{	my $l = shift @$args;
				$opt->{level} = lc($l);
			}
		}
		elsif ($o eq '--galaxy') {
			$opt->{galaxy} = 1;
		}
		else {
			push @$errs, "Ignored nonexistent option $o";
		}
	}
	return check_options($opt, $errs);
}


# process the input params
sub check_options {
	my ($opt, $errs) = @_;

	if (!$opt)
	{	MyLogger::init_with_config( 'standard' );
		$logger = MyLogger::get_logger();
		$logger->logdie("Error: please ensure you have specified two input files and an output file.\nThe help documentation can be accessed with the command 'compare-graphs.pl --help'.");
	}

	if (! $opt->{verbose})
	{	$opt->{verbose} = $ENV{GO_VERBOSE} || 0;
	}

	if ($opt->{verbose} || $ENV{DEBUG})
	{	MyLogger::init_with_config( 'verbose' );
		$logger = MyLogger::get_logger();
	}
	else
	{	MyLogger::init_with_config( 'standard' );
		$logger = MyLogger::get_logger();
	}

	if ($errs && @$errs)
	{	foreach (@$errs)
		{	$logger->error($_);
		}
	}
	undef $errs;

	foreach my $f qw(f1 f2)
	{	if (!$opt->{$f})
		{	push @$errs, "specify an input file using -$f /path/to/<file_name>";
		}
		elsif (! -e $opt->{$f})
		{	push @$errs, "the file " . $opt->{$f} . " could not be found.\n";
		}
		elsif (! -r $opt->{$f} || -z $opt->{$f})
		{	push @$errs, "the file " . $opt->{$f} . " could not be read.\n";
		}
	}

	if (! $errs )
	{	## quick 'diff' check of whether the files are identical or not
		my $cmd = "diff -w -q " . $opt->{f1} . " " . $opt->{f2};

		my $status = `$cmd`;
		if (! $status)
		{	$logger->logdie("The two files specified appear to be identical!");
		}
	}

	if (! $opt->{level})
	{	$opt->{level} = 'm';
	}
	else
	{	if (! grep { $_ eq $opt->{level} } qw(s m l short medium long) )
		{	push @$errs, "the output level " . $opt->{level} . " is invalid. Valid options are 'short', 'medium' and 'long'";
		}
		## abbreviate the level designator
		$opt->{level} = substr($opt->{level}, 0, 1)
	}

	if (!$opt->{mode})
	{	$opt->{mode} = 'text';
	}
	else
	{	if (! grep { $_ eq $opt->{mode} } qw(text html) )
		{	push @$errs, "the output mode " . $opt->{mode} . " is invalid. Valid options are 'text' and 'html'";
		}
	}

	if (!$opt->{output})
	{	push @$errs, "specify an output file using -o /path/to/<file_name>";
	}
	else
	{	if ($opt->{mode} eq 'html' && $opt->{output} !~ /html$/)
		{	$opt->{output} .= ".html";
			$logger->warn("Output will be saved in file " . $opt->{output});
		}
		## make sure that if the file exists, we can write to it
		if (-e $opt->{output} && ! -w $opt->{output})
		{	push @$errs, $opt->{output} . " already exists and cannot to be written to";
		}
	}

	## make sure that we can find the template directory!
	my @paths = split(":", $opt->{inc_path});
	my $pass;
	foreach (@paths)
	{	$_ =~ s/\/$//;
		if (-e $_ . "/" . $opt->{mode} . '_report.tmpl')
		{	$pass++;
			last;
		}
	}
	if (! $pass)
	{	push @$errs, "could not find the template file; check the paths in \$defaults->{inc_path}";
	}

#	if (! $opt->{subset} && ! $opt->{brief})
#	{	## no subset specified and in full text mode - must supply a subset
#		push @$errs, "specify a subset using -s <subset_name>";
#	}

	if ($errs && @$errs)
	{	$logger->logdie("Please correct the following parameters to run the script:\n" . ( join("\n", map { " - " . $_ } @$errs ) ) . "\nThe help documentation can be accessed with the command\n\tcompare-obo-files.pl --help");
	}

	return $opt;
}


=head1 AUTHOR

Amelia Ireland

=head1 SEE ALSO

L<GOBO::Graph>, L<GOBO::InferenceEngine>, L<GOBO::Doc::FAQ>

=cut
