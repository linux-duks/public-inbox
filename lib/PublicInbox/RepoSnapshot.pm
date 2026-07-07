# Copyright (C) all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# cgit-compatible /snapshot/ endpoint for WWW coderepos
package PublicInbox::RepoSnapshot;
use v5.12;
use PublicInbox::Qspawn;
use PublicInbox::ViewVCS;
use PublicInbox::WwwStatic qw(r);

# Not using standard mime types since the compressed tarballs are
# special or do not match my /etc/mime.types.  Choose what gitweb
# and cgit agree on for compatibility.
our %FMT_TYPES = (
	'tar' => 'application/x-tar',
	'tar.gz' => 'application/x-gzip',
	'tar.bz2' => 'application/x-bzip2',
	'tar.xz' => 'application/x-xz',
	'zip' => 'application/x-zip',
);

our %FMT_CFG = (
	'tar.xz' => 'xz -c',
	'tar.bz2' => 'bzip2 -c',
	# not supporting lz nor zstd for now to avoid format proliferation
	# and increased cache overhead required to handle extra formats.
);

my $SUFFIX = join('|', map { quotemeta } keys %FMT_TYPES);

# snapshots for untagged tree-ish:
my $OID_SUFFIX = qr!\b(?:[0-9a-f]{40}|[0-9a-f]{64})\z!;

# TODO deal with tagged blobs

sub archive_hdr { # parse_hdr for Qspawn
	my ($r, $bref, $ctx) = @_;
	$r or return [500, [qw(Content-Type text/plain Content-Length 0)], []];
	my $fn = "$ctx->{snap_pfx}.$ctx->{snap_fmt}";
	my $type = $FMT_TYPES{$ctx->{snap_fmt}} //
				die "BUG: bad fmt: $ctx->{snap_fmt}";
	[ 200, [ 'Content-Type', "$type; charset=UTF-8",
		'Content-Disposition', qq(inline; filename="$fn"),
		'ETag', qq("$ctx->{etag}") ] ];
}

sub ver_check { # git->check_async callback
	my (undef, $oid, $type, $size, $ctx) = @_;
	return if defined $ctx->{etag};
	my $treeish = shift @{$ctx->{-try}} // die 'BUG: no {-try}';
	if ($type eq 'missing') {
		scalar(@{$ctx->{-try}}) or
			delete($ctx->{env}->{'qspawn.wcb'})->(r(404));
	} else { # found, done:
		$ctx->{etag} = $oid;
		my $cmd = $ctx->{git}->cmd;
		if (my $cmd = $FMT_CFG{$ctx->{snap_fmt}}) {
			push @$cmd, '-c', "tar.$ctx->{snap_fmt}.command=$cmd";
		}
		push @$cmd, 'archive', "--prefix=$ctx->{snap_pfx}/",
				"--format=$ctx->{snap_fmt}", $treeish;
		my $qsp = PublicInbox::Qspawn->new($cmd, undef, { quiet => 1 });
		my $lim = $ctx->{snap_pfx} =~ $OID_SUFFIX
			? $ctx->{wcr}->{pi_cfg}->limiter('-oidsnapshot', 1)
			: undef;
		$qsp->psgi_yield($ctx->{env}, $lim, \&archive_hdr, $ctx);
	}
}

sub srv {
	my ($ctx, $fn) = @_;
	return if $fn =~ /["\s]/s;
	my $fmt = $ctx->{wcr}->{snapshots}; # TODO per-repo snapshots
	$fn =~ s/\.($SUFFIX)\z//o and $fmt->{$1} or return;
	$ctx->{snap_fmt} = $1;
	my $pfx = $ctx->{git}->local_nick // return;
	$pfx =~ s/(?:\.git)?\z/-/;
	($pfx) = ($pfx =~ m!([^/]+)\z!);
	substr($fn, 0, length($pfx)) eq $pfx or return;
	$ctx->{snap_pfx} = $fn;
	my $v = $ctx->{snap_ver} = substr($fn, length($pfx), length($fn));
	# try without [vV] prefix, first
	my @try = map { "$_$v" } ('', 'v', 'V'); # cf. cgit:ui-snapshot.c
	@{$ctx->{-try}} = @try;
	sub {
		$ctx->{env}->{'qspawn.wcb'} = $_[0];
		PublicInbox::ViewVCS::do_check_async($ctx, \&ver_check, @try);
	}
}

1;
