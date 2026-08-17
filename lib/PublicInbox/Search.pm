# Copyright (C) all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
# based on notmuch, but with no concept of folders, files or flags
#
# Read-only search interface for use by the web and NNTP interfaces
package PublicInbox::Search;
use strict;
use v5.10.1;
use parent qw(Exporter);
use PublicInbox::Lock;
our @EXPORT_OK = qw(retry_reopen int_val get_pct xap_terms);
use List::Util qw(max);
use POSIX qw(strftime);
use autodie qw(open pipe);
use Carp ();
our $XHC = 0; # defined but false

# values for searching, changing the numeric value breaks
# compatibility with old indices (so don't change them it)
use constant {
	TS => 0, # Received: in Unix time (IMAP INTERNALDATE, JMAP receivedAt)
	YYYYMMDD => 1, # redundant with DT below
	DT => 2, # Date: YYYYMMDDHHMMSS (IMAP SENT*, JMAP sentAt)

	# added for public-inbox 1.6.0+
	BYTES => 3, # IMAP RFC822.SIZE
	UID => 4, # IMAP UID == NNTP article number == Xapian docid
	THREADID => 5, # RFC 8474, RFC 8621

	# TODO
	# REPLYCNT => ?, # IMAP ANSWERED

	# SCHEMA_VERSION history
	# 0 - initial
	# 1 - subject_path is lower-cased
	# 2 - subject_path is id_compress in the index, only
	# 3 - message-ID is compressed if it includes '%' (hack!)
	# 4 - change "Re: " normalization, avoid circular Reference ghosts
	# 5 - subject_path drops trailing '.'
	# 6 - preserve References: order in document data
	# 7 - remove references and inreplyto terms (restored in 15 (v2.0))
	# 8 - remove redundant/unneeded document data
	# 9 - disable Message-ID compression (SHA-1)
	# 10 - optimize doc for NNTP overviews
	# 11 - merge threads when vivifying ghosts
	# 12 - change YYYYMMDD value column to numeric
	# 13 - fix threading for empty References/In-Reply-To
	#      (commit 83425ef12e4b65cdcecd11ddcb38175d4a91d5a0)
	# 14 - fix ghost root vivification
	# 15 - see public-inbox-v2-format(5)
	#      further bumps likely unnecessary, we'll suggest in-place
	#      "--reindex" use for further fixes and tweaks:
	#
	#      public-inbox v1.5.0 adds (still SCHEMA_VERSION=15):
	#      * "lid:" and "l:" for List-Id searches
	#
	#      v1.6.0 adds BYTES, UID and THREADID values
	#      v2.0.0 re-adds "references:"
	SCHEMA_VERSION => 15,

	# we may have up to 8 FDs per shard (depends on Xapian *shrug*)
	SHARD_COST => 8,
};

use PublicInbox::Smsg;
eval { require PublicInbox::Over };
our $QP_FLAGS;
our %X = map { $_ => 0 } qw(BoolWeight Database Enquire QueryParser Stem Query);
our $Xap; # 'Xapian' or 'Search::Xapian'
our $NVRP; # '$Xap::'.('NumberValueRangeProcessor' or 'NumberRangeProcessor')
our $MULTI_VALUE_SORTER; # Xapian::MultiValueKeyMaker or Search::Xapian::MultiValueSorter

# ENQ_DESCENDING and ENQ_ASCENDING weren't in SWIG Xapian.pm prior to 1.4.16,
# let's hope the ABI is stable
our $ENQ_DESCENDING = 0;
our $ENQ_ASCENDING = 1;
our @MAIL_VMAP = (
	[ YYYYMMDD, 'd:', 'YYYYmmdd' ], # enum date_fmt
	[ TS, 'rt:', 'epoch_sec' ],
	# these are undocumented for WWW, but lei and IMAP use them
	[ DT, 'dt:', 'YYYYmmddHHMMSS' ],
	[ BYTES, 'z:' ],
	[ UID, 'uid:' ]
);
our @MAIL_NRP;

# Getopt::Long spec, only short options for portability in C++ implementation
our @XH_SPEC = (
	'a', # ascending sort
	'c', # code search
	'd=s@', # shard dirs
	'g=s', # git dir (with -c)
	'k=i', # sort column (like sort(1))
	'l=s', # open.lock path
	'm=i', # maximum number of results
	'o=i', # offset
	'r', # 1=relevance then column
	't', # collapse threads
	'u=i', # IMAP UID min
	'A=s@', # prefixes
	'K=i', # timeout kill after i seconds
	'O=s', # eidx_key
	'T=i', # threadid
	'U=i', # IMAP UID max
	'Q=s@', # query prefixes "$user_prefix[:=]$XPREFIX"
);

sub load_xapian () {
	return 1 if defined $Xap;
	# n.b. PI_XAPIAN is intended for development use only
	for my $x (($ENV{PI_XAPIAN} // 'Xapian'), 'Search::Xapian') {
		eval "require $x";
		next if $@;

		$x->import(qw(:standard));
		$Xap = $x;

		# `version_string' was added in Xapian 1.1
		my $xver = eval('v'.eval($x.'::version_string()')) //
				eval('v'.eval($x.'::xapian_version_string()'));

		# NumberRangeProcessor was added in Xapian 1.3.6,
		# NumberValueRangeProcessor was removed for 1.5.0+,
		# continue with the older /Value/ variant for now...
		$NVRP = $x.'::'.($x eq 'Xapian' && $xver ge v1.5 ?
			'NumberRangeProcessor' : 'NumberValueRangeProcessor');
		$MULTI_VALUE_SORTER = $x eq 'Xapian' ?
			'Xapian::MultiValueKeyMaker' :
			'Search::Xapian::MultiValueSorter';
		$X{$_} = $Xap.'::'.$_ for (keys %X);

		*sortable_serialise = $x.'::sortable_serialise';
		*sortable_unserialise = $x.'::sortable_unserialise';
		# n.b. FLAG_PURE_NOT is expensive not suitable for a public
		# website as it could become a denial-of-service vector
		# FLAG_PHRASE also seems to cause performance problems chert
		# (and probably earlier Xapian DBs).  glass seems fine...
		# TODO: make this an option, maybe?
		# or make indexlevel=medium as default
		$QP_FLAGS = FLAG_PHRASE() | FLAG_BOOLEAN() | FLAG_LOVEHATE() |
				FLAG_WILDCARD();
		@MAIL_NRP = map { $NVRP->new(@$_[0, 1]) } @MAIL_VMAP;
		return 1;
	}
	undef;
}

# This is English-only, everything else is non-standard and may be confused as
# a prefix common in patch emails
our $LANG = 'english';

our %PATCH_BOOL_COMMON = (
	dfpre => 'XDFPRE',
	dfpost => 'XDFPOST',
	dfblob => 'XDFPRE XDFPOST',
	patchid => 'XDFID',
);

# note: the non-X term prefix allocations are shared with
# Xapian omega, see xapian-applications/omega/docs/termprefixes.rst
my %bool_pfx_external = (
	mid => 'Q', # Message-ID (full/exact), this is mostly uniQue
	lid => 'G', # newsGroup (or similar entity), just inside <>
	references => 'XRF',
	%PATCH_BOOL_COMMON
);

# for mairix compatibility
our $NON_QUOTED_BODY = 'XNQ XDFN XDFA XDFB XDFHH XDFCTX XDFPRE XDFPOST XDFID';
our %PATCH_PROB_COMMON = (
	s => 'S',
	f => 'A',
	b => $NON_QUOTED_BODY . ' XQUOT',
	bs => $NON_QUOTED_BODY . ' XQUOT S',
	n => 'XFN',

	q => 'XQUOT',
	nq => $NON_QUOTED_BODY,
	dfn => 'XDFN',
	dfa => 'XDFA',
	dfb => 'XDFB',
	dfhh => 'XDFHH',
	dfctx => 'XDFCTX',
);

my %prob_prefix = (
	m => 'XM', # 'mid:' (bool) is exact, 'm:' (prob) can do partial
	l => 'XL', # 'lid:' (bool) is exact, 'l:' (prob) can do partial
	t => 'XTO',
	tc => 'XTO XCC',
	c => 'XCC',
	tcf => 'XTO XCC A',
	a => 'XTO XCC A',
	%PATCH_PROB_COMMON,
	# default:
	'' => 'XM S A XQUOT XFN ' . $NON_QUOTED_BODY,
);

# not documenting m: and mid: for now, the using the URLs works w/o Xapian
# not documenting lid: for now, either, it is probably redundant with l:,
# especially since we don't offer boolean searches for To/Cc/From
# headers, either
our @HELP = (
	s => 'match within Subject  e.g. s:"a quick brown fox"',
	d => <<EOF,
match date-time range, git "approxidate" formats supported
Open-ended ranges such as `d:last.week..' and
`d:..2.days.ago' are supported
EOF
	b => 'match within message body, including text attachments',
	nq => 'match non-quoted text within message body',
	q => 'match quoted text within message body',
	n => 'match filename of attachment(s)',
	t => 'match within the To header',
	c => 'match within the Cc header',
	f => 'match within the From header',
	a => 'match within the To, Cc, and From headers',
	tc => 'match within the To and Cc headers',
	l => 'match contents of the List-Id header',
	bs => 'match within the Subject and body',
	dfn => 'match filename from diff',
	dfa => 'match diff removed (-) lines',
	dfb => 'match diff added (+) lines',
	dfhh => 'match diff hunk header context (usually a function name)',
	dfctx => 'match diff context lines',
	dfpre => 'match pre-image git blob ID',
	dfpost => 'match post-image git blob ID',
	dfblob => 'match either pre or post-image git blob ID',
	patchid => "match `git patch-id --stable' output",
	rt => <<EOF,
match received time, like `d:' if sender's clock was correct
EOF
);
chomp @HELP;

sub xdir ($;$) {
	my ($self, $rdonly) = @_;
	if ($rdonly || !defined($self->{shard})) {
		$self->{xpfx};
	} else { # v2, extindex, cindex only:
		"$self->{xpfx}/$self->{shard}";
	}
}

# returns shard directories as an array of strings, does not verify existence
sub shard_dirs ($) {
	my ($self) = @_;
	my $xpfx = $self->{xpfx};
	if ($xpfx =~ m!/xapian[0-9]+\z!) { # v1 inbox
		($xpfx);
	} else { # v2 inbox, eidx, cidx
		opendir(my $dh, $xpfx) or return (); # not initialized yet
		# We need numeric sorting so shard[0] is first for reading
		# Xapian metadata, if needed
		my $last = max(grep(/\A[0-9]+\z/, readdir($dh))) // return ();
		map { "$xpfx/$_" } (0..$last);
	}
}

sub open_lock ($) { "$_[0]->{xpfx}/../open.lock" }

# returns all shards as separate Xapian::Database objects w/o combining
sub xdb_shards_flat ($) {
	my ($self) = @_;
	load_xapian();
	$self->{qp_flags} //= $QP_FLAGS;
	my $slow_phrase;
	my $lk = PublicInbox::Lock::may_sh open_lock($self);
	my @xdb = map {
		$slow_phrase ||= -f "$_/iamchert";
		$X{Database}->new($_); # raises if missing
	} shard_dirs($self);
	$self->{qp_flags} |= FLAG_PHRASE() if !$slow_phrase;
	@xdb;
}

# v2 Xapian docids don't conflict, so they're identical to
# NNTP article numbers and IMAP UIDs.
# https://trac.xapian.org/wiki/FAQ/MultiDatabaseDocumentID
sub mdocid {
	my ($nshard, $mitem) = @_;
	my $docid = $mitem->get_docid;
	int(($docid - 1) / $nshard) + 1;
}

sub docids_to_artnums {
	my $nshard = shift->{nshard};
	# XXX does array vs arrayref make a difference in modern Perls?
	map { int(($_ - 1) / $nshard) + 1 } @_;
}

sub mset_to_artnums {
	my ($self, $mset) = @_;
	my $nshard = $self->{nshard};
	[ map { mdocid($nshard, $_) } $mset->items ];
}

sub xdb ($) {
	my ($self) = @_;
	$self->{xdb} // do {
		my @xdb = $self->xdb_shards_flat or return;
		$self->{nshard} = scalar(@xdb);
		my $xdb = shift @xdb;
		$xdb->add_database($_) for @xdb;
		$self->{xdb} = $xdb;
	};
}

sub load_extra_indexers ($$) {
	my ($self, $ibx) = @_;
	my @extra;
	for my $f (qw(IndexHeader AltId)) {
		my $specs = $ibx->{lc $f} // next;
		my $cls = "PublicInbox::$f";
		eval "require $cls" or die $@;
		push @extra, map { $cls->new($ibx, $_) } @$specs;
	}
	$self->{-extra} = \@extra if @extra;
}

sub new {
	my ($class, $ibx) = @_;
	ref $ibx or die "BUG: expected PublicInbox::Inbox object: $ibx";
	my $xap = $ibx->version > 1 ? 'xap' : 'public-inbox/xapian';
	my $xpfx = "$ibx->{inboxdir}/$xap".SCHEMA_VERSION;
	my $self = bless { xpfx => $xpfx }, $class;
	$self->load_extra_indexers($ibx);
	$self;
}

sub reopen {
	my ($self) = @_;
	if (my $xdb = $self->{xdb}) {
		my $lk = defined($self->{xpfx}) ?
			PublicInbox::Lock::may_sh(open_lock($self)) :
			undef;
		$xdb->reopen;
	}
	$self; # make chaining easier
}

# Convert git "approxidate" ranges to something usable with our
# Xapian indices.  At the moment, Xapian only offers a C++-only API
# and neither the SWIG nor XS bindings allow us to use custom code
# to parse dates (and libgit2 doesn't expose git_date_parse publicly,
# either, so we're running git-rev-parse(1)).
# This replaces things we need to send to $git->date_parse with
# "\0".$strftime_format.['+'|$idx]."\0" placeholders
sub date_parse_prepare {
	my ($to_parse, $pfx, $range) = @_;
	# are we inside a parenthesized statement?
	my $end = $range =~ s/([\)\s]*)\z// ? $1 : '';
	my @r = split(/\.\./, $range, 2);

	# expand "dt:2010-10-02" => "dt:2010-10-02..2010-10-03" and like
	# n.b. git doesn't do YYYYMMDD w/o '-', it needs YYYY-MM-DD
	if ($pfx eq 'd') {
		if (!defined($r[1])) { # git needs gaps and not /\d{14}/
			if ($r[0] =~ /\A([0-9]{4})([0-9]{2})([0-9]{2})\z/) {
				push @$to_parse, "$1-$2-$3 00:00:00";
			} else {
				push @$to_parse, $r[0];
			}
			$r[0] = "\0%Y%m%d$#$to_parse\0";
			$r[1] = "\0%Y%m%d+\0";
		} else {
			for (@r) {
				next if $_ eq '' || /\A[0-9]{8}\z/;
				push @$to_parse, $_;
				$_ = "\0%Y%m%d$#$to_parse\0";
			}
		}
	} elsif ($pfx eq 'dt') {
		if (!defined($r[1])) { # git needs gaps and not /\d{14}/
			if ($r[0] =~ /\A([0-9]{4})([0-9]{2})([0-9]{2})
					([0-9]{2})([0-9]{2})([0-9]{2})\z/x) {
				push @$to_parse, "$1-$2-$3 $4:$5:$6";
			} else {
				push @$to_parse, $r[0];
			}
			$r[0] = "\0%Y%m%d%H%M%S$#$to_parse\0";
			$r[1] = "\0%Y%m%d%H%M%S+\0";
		} else {
			for my $x (@r) {
				next if $x eq '' || $x =~ /\A[0-9]{14}\z/;
				push @$to_parse, $x;
				$x = "\0%Y%m%d%H%M%S$#$to_parse\0";
			}
		}
	} else { # (rt|ct), let git interpret "YYYY", deal with Y10K later :P
		for my $x (@r) {
			next if $x eq '' || $x =~ /\A[0-9]{5,}\z/;
			push @$to_parse, $x;
			$x = "\0%s$#$to_parse\0";
		}
		$r[1] //= "\0%s+\0"; # add 1 day
	}
	"$pfx:".join('..', @r).$end;
}

sub date_parse_finalize {
	my ($git, $to_parse) = @_;
	# git-rev-parse can handle any number of args up to system
	# limits (around (4096*32) bytes on Linux).
	my @r = $git->date_parse(@$to_parse);
	# n.b. git respects TZ, times stored in SQLite/Xapian are always UTC,
	# and gmtime doesn't seem to do the right thing when TZ!=UTC
	my ($i, $t);
	$_[2] =~ s/\0(%[%YmdHMSs]+)([0-9\+]+)\0/
		$t = $2 eq '+' ? ($r[$i]+86400) : $r[$i=$2+0];
		$1 eq '%s' ? $t : strftime($1, gmtime($t))/sge;
}

# Try to make raw lei CLI args work more like the HTML <input> element.
# That is, that phrases quoted to keep the CLI happy (e.g. sh/bash/zsh)
# don't need extra (nested) quoting to make Xapian see the quotes for a phrase.
# n.b. argv never has NULL, though we'll need to filter it out
# if this $argv isn't from a command execution
sub query_argv_to_string {
	my (undef, $git, $argv) = @_;
	if ($XHC && $XHC->{impl} eq 'PublicInbox::XapHelperCxx') {
		join ' ', map {;
			if (/\s/) { # n.b. $1 may be `('
				s/(.*?)\b(\w+:)// ? qq{$1$2"$_"} : qq{"$_"};
			} else {
				$_
			}
		} @$argv;
	} else {
		my $to_parse;
		my $tmp = join ' ', map {;
			if (s!\b(d|rt|dt):(\S+)\z!date_parse_prepare(
						$to_parse //= [], $1, $2)!sge) {
				$_;
			} elsif (/\s/) { # n.b. $1 may be `('
				s/(.*?)\b(\w+:)// ? qq{$1$2"$_"} : qq{"$_"};
			} else {
				$_
			}
		} @$argv;
		date_parse_finalize($git, $to_parse, $tmp) if $to_parse;
		$tmp
	}
}

# this is for the WWW "q=" query parameter and "lei q --stdin"
# it can't do d:"5 days ago", but it will do d:5.days.ago
sub query_approxidate {
	return if $XHC && $XHC->{impl} eq 'PublicInbox::XapHelperCxx';
	my (undef, $git) = @_; # $_[2] = $query_string (modified in-place)
	my $DQ = qq<"\x{201c}\x{201d}>; # Xapian can use curly quotes
	$_[2] =~ tr/\x00/ /; # Xapian doesn't do NUL, we use it as a placeholder
	my ($terms, $phrase, $to_parse);
	$_[2] =~ s{([^$DQ]*)([$DQ][^$DQ]*[$DQ])?}{
		($terms, $phrase) = ($1, $2);
		$terms =~ s!\b(d|rt|dt):(\S+)!
			date_parse_prepare($to_parse //= [], $1, $2)!sge;
		$terms.($phrase // '');
		}sge;
	date_parse_finalize($git, $to_parse, $_[2]) if $to_parse;
}

# read-only, for mail only (codesearch has different rules)
sub mset {
	my ($self, $qry_str, $opt) = @_;
	my $qp = $self->{qp} // $self->qparse_new;
	my $qry = $qp->parse_query($qry_str, $self->{qp_flags});
	if (defined(my $eidx_key = $opt->{eidx_key})) {
		$qry = $X{Query}->new(OP_FILTER(), $qry, 'O'.$eidx_key);
	}
	if (defined(my $uid_range = $opt->{uid_range})) {
		my $range = $X{Query}->new(OP_VALUE_RANGE(), UID,
					sortable_serialise($uid_range->[0]),
					sortable_serialise($uid_range->[1]));
		$qry = $X{Query}->new(OP_FILTER(), $qry, $range);
	}
	if (defined(my $tid = $opt->{threadid})) {
		$tid = sortable_serialise($tid);
		$qry = $X{Query}->new(OP_FILTER(), $qry,
			$X{Query}->new(OP_VALUE_RANGE(), THREADID, $tid, $tid));
	}
	$opt->{sort_col} //= TS;
	do_enquire($self, $qry, $opt);
}

my %QPMETHOD_2_SYM = (add_prefix => ':', add_boolean_prefix => '=');

sub xh_opt ($$) {
	my ($self, $opt) = @_;
	my $lim = $opt->{limit} || 50;
	my @ret;
	push @ret, '-o', $opt->{offset} if $opt->{offset};
	push @ret, '-m', $lim;
	push @ret, '-r' if $opt->{relevance};
	push @ret, '-k', $opt->{sort_col} // TS;
	push @ret, '-a' if $opt->{asc};
	push @ret, '-t' if $opt->{threads};
	push @ret, '-T', $opt->{threadid} if defined $opt->{threadid};
	push @ret, '-O', $opt->{eidx_key} if defined $opt->{eidx_key};
	if (my $uid = $opt->{uid_range}) {
		push @ret, '-u', $uid->[0], '-U', $uid->[1];
	}
	@ret;
}

# returns a true value if actually handled asynchronously,
# and a falsy value if handled synchronously
sub async_mset {
	my ($self, $qry, $opt, $cb, @args) = @_;
	if ($XHC) { # unconditionally retrieving pct + rank for now
		xdb($self); # populate {nshards}
		my @margs = ($self->xh_args, xh_opt($self, $opt), '--');
		my $ret = eval {
			pipe my $out_rd, my $out_wr;
			open my $err_rw, '+>', undef;
			$XHC->mkreq([ $out_wr, $err_rw ], 'mset', @margs,
				(ref($qry) eq 'ARRAY' ? @$qry : $qry));
			undef $out_wr;
			PublicInbox::XhcMset->maybe_new($out_rd, $err_rw,
							$self, $cb, @args);
		};
		$cb->(@args, undef, $@) if $@;
		$ret;
	} else { # synchronous
		my $mset;
		for my $qstr (ref($qry) eq 'ARRAY' ? @$qry : ($qry)) {
			$mset = eval { $self->mset($qstr, $opt) };
			last if $mset && $mset->size;
		}
		$mset ? $cb->(@args, $mset) : $cb->(@args, undef, $@ || 'err');
		undef;
	}
}

sub do_enquire { # shared with CodeSearch and MiscSearch
	my ($self, $qry, $opt) = @_;
	my $enq = $X{Enquire}->new(xdb($self));
	$enq->set_query($qry);
	if (my $km = $opt->{sort_keymaker}) {
		my $rev = $opt->{asc} ? 1 : 0;
		if ($opt->{relevance}) {
			$enq->set_sort_by_relevance_then_key($km, $rev);
		} else {
			$enq->set_sort_by_key_then_relevance($km, $rev);
		}
	} else {
		my $col = $opt->{sort_col} // TS;
		if ($col < 0) {
			$enq->set_weighting_scheme($X{BoolWeight}->new);
			$enq->set_docid_order(
				$opt->{asc} ? $ENQ_ASCENDING :
				$ENQ_DESCENDING);
		} elsif ($opt->{relevance}) {
			$enq->set_sort_by_relevance_then_value($col,
				!$opt->{asc});
		} else {
			$enq->set_sort_by_value_then_relevance($col,
				!$opt->{asc});
		}
	}
	# `lei q -t / --threads' or JMAP collapseThreads; but don't collapse
	# on `-tt' ({threads} > 1) which sets the Flagged|Important keyword
	(($opt->{threads} // 0) == 1 && has_threadid($self)) and
		$enq->set_collapse_key(THREADID);
	retry_reopen($self, \&enquire_once, $enq,
			$opt->{offset} || 0, $opt->{limit} || 50);
}

sub retry_reopen {
	my ($self, $cb, @arg) = @_;
	for my $i (1..10) {
		if (wantarray) {
			my @ret = eval { $cb->($self, @arg) };
			return @ret unless $@;
		} else {
			my $ret = eval { $cb->($self, @arg) };
			return $ret unless $@;
		}
		# Exception: The revision being read has been discarded -
		# you should call Xapian::Database::reopen()
		if (ref($@) =~ /\bDatabaseModifiedError\b/) {
			reopen($self);
		} else {
			# let caller decide how to spew, because ExtMsg queries
			# get wonky and trigger:
			# "something terrible happened at .../Xapian/Enquire.pm"
			Carp::croak($@);
		}
	}
	Carp::croak("Too many Xapian database modifications in progress\n");
}

# returns true if all docs have the THREADID value
sub has_threadid ($) {
	my ($self) = @_;
	(xdb($self)->get_metadata('has_threadid') // '') eq '1';
}

sub enquire_once { # retry_reopen callback
	my (undef, $enq, $offset, $limit) = @_;
	$enq->get_mset($offset, $limit);
}

sub mset_to_smsg {
	my ($self, $ibx, $mset) = @_;
	my $nshard = $self->{nshard};
	my $i = 0;
	my %order = map { mdocid($nshard, $_) => ++$i } $mset->items;
	my @msgs = sort {
		$order{$a->{num}} <=> $order{$b->{num}}
	} @{$ibx->over->get_all(keys %order)};
	wantarray ? ($mset->get_matches_estimated, \@msgs) : \@msgs;
}

# read-write
sub stemmer { $X{Stem}->new($LANG) }

sub qp_init_common {
	my ($self) = @_;
	my $qp = $self->{qp} = $X{QueryParser}->new;
	$qp->set_default_op(OP_AND());
	$qp->set_database(xdb($self));
	$qp->set_stemmer(stemmer($self));
	$qp->set_stemming_strategy(STEM_SOME());
	my $cb = $qp->can('set_max_wildcard_expansion') //
		$qp->can('set_max_expansion'); # Xapian 1.5.0+
	$cb->($qp, 100);
	$qp;
}

# read-only
sub qparse_new {
	my ($self) = @_;
	my $qp = qp_init_common($self);
	my $cb = $qp->can('add_valuerangeprocessor') //
		$qp->can('add_rangeprocessor'); # Xapian 1.5.0+

	$cb->($qp, $_) for @MAIL_NRP;
	while (my ($name, $prefix) = each %bool_pfx_external) {
		$qp->add_boolean_prefix($name, $_) foreach split(/ /, $prefix);
	}

	for my $x (@{$self->{-extra} // []}) {
		my $m = $x->query_parser_method;
		$qp->$m(@$x{qw(prefix xprefix)});
	}
	while (my ($name, $prefix) = each %prob_prefix) {
		$qp->add_prefix($name, $_) foreach split(/ /, $prefix);
	}
	$qp;
}

sub generate_cxx () { # generates snippet for xap_helper.h
	my $gdfp_size = grep { @$_ == 3 } @MAIL_VMAP;
	my @gdfp_pfx;
	my $ret = <<EOM;
# line ${\__LINE__} "${\__FILE__}"
static RP *mail_rp[${\scalar(@MAIL_VMAP)}];
static GitDateFieldProcessor *mail_gdfp[$gdfp_size];
static void mail_rp_init(void)
{
EOM
	for (0..$#MAIL_VMAP) {
		my $x = $MAIL_VMAP[$_];
		if (@$x == 3) {
			push @gdfp_pfx, $x->[1];
			$ret .= <<"";
	mail_rp[$_] = new GitDateRangeProcessor($x->[0], "$x->[1]", $x->[2]);
	mail_gdfp[$#gdfp_pfx] = new GitDateFieldProcessor($x->[0], $x->[2]);

		} else {
			$ret .= <<"";
	mail_rp[$_] = new NRP($x->[0], "$x->[1]");

		}
	}
$ret .= <<EOM;
}

# line ${\__LINE__} "${\__FILE__}"
static void qp_init_mail_search(Xapian::QueryParser *qp)
{
	for (size_t i = 0; i < MY_ARRAY_SIZE(mail_rp); i++)
		qp->ADD_RP(mail_rp[i]);
EOM
	for my $name (sort keys %bool_pfx_external) {
		for (split(/ /, $bool_pfx_external{$name})) {
			$ret .= qq{\tqp->add_boolean_prefix("$name", "$_");\n}
		}
	}
	my $i = 0;
	for (@gdfp_pfx) {
		$ret .= qq{\tqp->add_boolean_prefix("$_", mail_gdfp[$i]);\n};
		++$i;
	}
	# altid support is handled in xh_opt and srch_init_extra in XH
	for my $name (sort keys %prob_prefix) {
		for (split(/ /, $prob_prefix{$name})) {
			$ret .= qq{\tqp->add_prefix("$name", "$_");\n}
		}
	}
	$ret .= "}\n";
}

sub help2txt (@) { # also used by Documentation/common.perl
	my @help = @_;
	my $pad = 0;
	my $htxt = '';
	while (defined(my $pfx = shift @help)) {
		my $n = length($pfx) + 1;
		$pad = $n if $n > $pad;
		$htxt .= $pfx . ":\0" . shift(@help) . "\f\n";
	}
	$pad += 2;
	my $padding = ' ' x ($pad + 4);
	$htxt =~ s/^/$padding/gms;
	$htxt =~ s/^$padding(\S+)\0/"    $1".(' ' x ($pad - length($1)))/egms;
	$htxt =~ s/\f\n/\n/gs;
	$htxt;
}

sub help_txt {
	help2txt(@HELP, map { $_->user_help } @{$_[0]->{-extra} // []});
}

# always returns a scalar value
sub int_val ($$) {
	my ($doc, $col) = @_;
	my $val = $doc->get_value($col) or return undef; # undef is '' in Xapian
	sortable_unserialise($val) + 0; # PV => IV conversion
}

sub get_pct ($) { # mset item
	# Capped at "99%" since "100%" takes an extra column in the
	# thread skeleton view.  <xapian/mset.h> says the value isn't
	# very meaningful, anyways.
	my $n = $_[0]->get_percent;
	$n > 99 ? 99 : $n;
}

sub xap_terms ($$;@) {
	my ($pfx, $xdb_or_doc, @docid) = @_; # @docid may be empty ()
	my $end = $xdb_or_doc->termlist_end(@docid);
	my $cur = $xdb_or_doc->termlist_begin(@docid);
	$cur->skip_to($pfx);
	my (@ret, $tn);
	my $pfxlen = length($pfx);
	for (; $cur != $end; $cur++) {
		$tn = $cur->get_termname;
		index($tn, $pfx) ? last : push(@ret, substr($tn, $pfxlen));
	}
	wantarray ? @ret : +{ map { $_ => undef } @ret };
}

# get combined docid from over.num:
# (not generic Xapian, only works with our sharding scheme for mail)
sub num2docid ($$) {
	my ($self, $num) = @_;
	my $nshard = $self->{nshard};
	($num - 1) * $nshard + $num % $nshard + 1;
}

sub all_terms {
	my ($self, $pfx) = @_;
	my $cur = xdb($self)->allterms_begin($pfx);
	my $end = $self->{xdb}->allterms_end($pfx);
	my $pfxlen = length($pfx);
	my @ret;
	for (; $cur != $end; $cur++) {
		push @ret, substr($cur->get_termname, $pfxlen);
	}
	wantarray ? @ret : +{ map { $_ => undef } @ret };
}

sub xh_args { # prep getopt args to feed to xap_helper.h socket
	my ($self) = @_;
	my $apfx = $self->{-alt_pfx} //= do {
		my %dedupe;
		for my $x (@{$self->{-extra} // []}) {
			my $sym = $QPMETHOD_2_SYM{$x->query_parser_method};
			$dedupe{$x->{prefix}.$sym.$x->{xprefix}} = undef;
		}
		# TODO: arbitrary header indexing goes here
		my @apfx = map { ('-Q', $_) } sort keys %dedupe;
		\@apfx;
	};
	((map { ('-d', $_) } $self->shard_dirs), $self->xh_lock_args, @$apfx);
}

sub xh_lock_args { ('-l', open_lock($_[0])) }

sub docids_by_postlist ($$) {
	my ($self, $q) = @_;
	my $cur = $self->xdb->postlist_begin($q);
	my $end = $self->{xdb}->postlist_end($q);
	my @ids;
	for (; $cur != $end; $cur++) { push(@ids, $cur->get_docid) };
	@ids;
}

sub get_doc ($$) {
	my ($self, $docid) = @_;
	eval { $self->{xdb}->get_document($docid) } // do {
		die $@ if $@ && ref($@) !~ /\bDocNotFoundError\b/;
		undef;
	}
}

# not sure where best to put this...
sub ulimit_n () {
	my $n;
	if (eval { require BSD::Resource; 1 }) {
		my $NOFILE = BSD::Resource::RLIMIT_NOFILE();
		($n, undef) = BSD::Resource::getrlimit($NOFILE);
	} else {
		require PublicInbox::Spawn;
		$n = PublicInbox::Spawn::run_qx([qw(/bin/sh -c), 'ulimit -n']);
	}
	$n;
}

1;
