# Copyright (C) all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
#
# Used throughout the project for reading configuration
#
# Note: I hate camelCase; but git-config(1) uses it, but it's better
# than alllowercasewithoutunderscores, so use lc('configKey') where
# applicable for readability

package PublicInbox::Config;
use strict;
use v5.10.1;
use parent qw(Exporter);
our @EXPORT_OK = qw(glob2re rel2abs_collapsed);
use PublicInbox::Inbox;
use PublicInbox::Git qw(git_exe);
use PublicInbox::Spawn qw(popen_rd run_qx);
our $LD_PRELOAD = $ENV{LD_PRELOAD}; # only valid at startup
our $DEDUPE; # set to {} to dedupe or clear cache
use autodie qw(closedir);

sub _array ($) { ref($_[0]) eq 'ARRAY' ? $_[0] : [ $_[0] ] }

# returns key-value pairs of config directives in a hash
# if keys may be multi-value, the value is an array ref containing all values
sub new {
	my ($class, $file, $lei) = @_;
	$file //= default_file();
	my ($self, $set_dedupe);
	if (-f $file && $DEDUPE) {
		$file = rel2abs_collapsed($file);
		$self = $DEDUPE->{$file} and return $self;
		$set_dedupe = 1;
	}
	$self = git_config_dump($class, $file, $lei);
	$self->{-f} = $file;
	# caches
	$self->{-by_addr} = {};
	$self->{-by_list_id} = {};
	$self->{-by_name} = {};
	$self->{-by_newsgroup} = {};
	$self->{-by_eidx_key} = {};
	$self->{-no_obfuscate} = {};
	$self->{-limiters} = {};
	$self->{-coderepos} = {}; # nick => PublicInbox::Git object

	if (my $no = delete $self->{'publicinbox.noobfuscate'}) {
		$no = _array($no);
		my @domains;
		foreach my $n (@$no) {
			my @n = split(/\s+/, $n);
			foreach (@n) {
				if (/\S+@\S+/) { # full address
					$self->{-no_obfuscate}->{lc $_} = 1;
				} else {
					# allow "example.com" or "@example.com"
					s/\A@//;
					push @domains, quotemeta($_);
				}
			}
		}
		my $nod = join('|', @domains);
		$self->{-no_obfuscate_re} = qr/(?:$nod)\z/i;
	}
	if (my $css = delete $self->{'publicinbox.css'}) {
		$self->{css} = _array($css);
	}
	if (my $html_head = delete $self->{'publicinbox.htmlhead'}) {
		$self->{html_head} = _array($html_head);
	}
	$DEDUPE->{$file} = $self if $set_dedupe;
	$self;
}

sub noop {}
sub fill_all ($) { each_inbox($_[0], \&noop) }

sub _lookup_fill ($$$) {
	my ($self, $cache, $key) = @_;
	$self->{$cache}->{$key} // do {
		fill_all($self);
		$self->{$cache}->{$key};
	}
}

sub lookup {
	my ($self, $recipient) = @_;
	_lookup_fill($self, '-by_addr', lc($recipient));
}

sub lookup_list_id {
	my ($self, $list_id) = @_;
	_lookup_fill($self, '-by_list_id', lc($list_id));
}

sub lookup_name ($$) {
	my ($self, $name) = @_;
	$self->{-by_name}->{$name} // _fill_ibx($self, $name);
}

sub lookup_ei {
	my ($self, $name) = @_;
	$self->{-ei_by_name}->{$name} //= _fill_ei($self, $name);
}

sub lookup_eidx_key {
	my ($self, $eidx_key) = @_;
	_lookup_fill($self, '-by_eidx_key', $eidx_key);
}

# special case for [extindex "all"]
sub ALL { lookup_ei($_[0], 'all') }

sub each_inbox {
	my ($self, $cb, @arg) = @_;
	# may auto-vivify if config file is non-existent:
	foreach my $section (@{$self->{-section_order}}) {
		next if $section !~ m!\Apublicinbox\.([^/]+)\z!;
		my $ibx = lookup_name($self, $1) or next;
		$cb->($ibx, @arg);
	}
}

sub lookup_newsgroup {
	my ($self, $ng) = @_;
	_lookup_fill($self, '-by_newsgroup', lc($ng));
}

sub limiter {
	my ($self, $name, $max_default) = @_;
	$self->{-limiters}->{$name} //= do {
		require PublicInbox::Limiter;
		my $l = PublicInbox::Limiter->new($max_default || 1);
		$l->setup_limiter($name, $self);
		$l;
	};
}

sub config_dir { $ENV{PI_DIR} // "$ENV{HOME}/.public-inbox" }

sub default_file {
	$ENV{PI_CONFIG} // (config_dir() . '/config');
}

sub config_fh_parse ($) {
	my ($fh) = @_;
	my (%rv, %seen, @section_order, $line, $k, $v, $section, $cur, $i);
	local $/ = "\0";
	while (defined($line = <$fh>)) { # perf critical with giant configs
		$i = index($line, "\n");
		# $i may be -1 if "\n" isn't found and it's a key-only entry
		# (meaning boolean true).  Either way the -1 will drop the
		# "\n" either from $k or $v.
		$k = substr($line, 0, $i);
		$v = $i >= 0 ? substr($line, $i + 1, -1) : 1;
		$section = substr($k, 0, rindex($k, '.'));
		$seen{$section} //= push(@section_order, $section);

		if (defined($cur = $rv{$k})) {
			if (ref($cur) eq "ARRAY") {
				push @$cur, $v;
			} else {
				$rv{$k} = [ $cur, $v ];
			}
		} else {
			$rv{$k} = $v;
		}
	}
	$rv{-section_order} = \@section_order;

	\%rv;
}

sub tmp_cmd_opt ($$) {
	my ($env, $opt) = @_;
	# quiet global and system gitconfig if supported by installed git,
	# but normally harmless if too noisy (NOGLOBAL no longer exists)
	$env->{GIT_CONFIG_NOSYSTEM} = 1;
	$env->{GIT_CONFIG_GLOBAL} = '/dev/null'; # git v2.32+
	$opt->{-C} = '/'; # avoid $worktree/.git/config on MOST systems :P
}

sub git_config_dump {
	my ($class, $file, $lei) = @_;
	my @opt_c = map { ('-c', $_) } @{$lei->{opt}->{c} // []};
	$file = undef if !-e $file;
	# XXX should we set {-f} if !-e $file?
	return bless {}, $class if (!@opt_c && !defined($file));
	my %env;
	my $opt = { 2 => $lei->{2} // 2 };
	if (@opt_c) {
		if (defined $file) {
			$file = rel2abs_collapsed($file); # for $opt->{-C}
			unshift @opt_c, '-c', "include.path=$file";
		}
		tmp_cmd_opt(\%env, $opt);
	}
	my @cmd = (git_exe, @opt_c, qw(config -z -l --includes));
	push(@cmd, '-f', $file) if !@opt_c && defined($file);
	my $fh = popen_rd(\@cmd, \%env, $opt);
	my $rv = config_fh_parse $fh;
	$fh->close or die "@cmd failed: \$?=$?\n";
	$rv->{-opt_c} = \@opt_c if @opt_c; # for ->urlmatch
	$rv->{-f} = $file;
	bless $rv, $class;
}

sub valid_foo_name ($;$) {
	my ($name, $pfx) = @_;

	# Similar rules found in git.git/remote.c::valid_remote_nick
	# and git.git/refs.c::check_refname_component
	# We don't reject /\.lock\z/, however, since we don't lock refs
	if ($name eq '' || $name =~ /\@\{/ ||
	    $name =~ /\.\./ || $name =~ m![/:\?\[\]\^~\s\f[:cntrl:]\*]! ||
	    $name =~ /\A\./ || $name =~ /\.\z/) {
		warn "invalid $pfx name: `$name'\n" if $pfx;
		return 0;
	}

	# Note: we allow URL-unfriendly characters; users may configure
	# non-HTTP-accessible inboxes
	1;
}

# XXX needs testing for cgit compatibility
# cf. cgit/scan-tree.c::add_repo
sub cgit_repo_merge ($$$) {
	my ($self, $base, $repo) = @_;
	my $path = $repo->{dir};
	if (defined(my $se = $self->{-cgit_strict_export})) {
		return unless -e "$path/$se";
	}
	return if -e "$path/noweb";
	# this comes from the cgit config, and AFAIK cgit only allows
	# repos to have one URL, but that's just the PATH_INFO component,
	# not the Host: portion
	# $repo = { url => 'foo.git', dir => '/path/to/foo.git' }
	my $rel = $repo->{url};
	unless (defined $rel) {
		my $off = index($path, $base, 0);
		if ($off != 0) {
			$rel = $path;
		} else {
			$rel = substr($path, length($base) + 1);
		}

		$rel =~ s!/\.git\z!! or
			$rel =~ s!/+\z!!;

		$self->{-cgit_remove_suffix} and
			$rel =~ s!/?\.git\z!!;
	}
	$self->{"coderepo.$rel.dir"} //= $path;
}

sub is_git_dir ($) {
	my ($git_dir) = @_;
	-d "$git_dir/objects" && -f "$git_dir/HEAD";
}

# XXX needs testing for cgit compatibility
sub scan_path_coderepo {
	my ($self, $base, $path) = @_;
	opendir(my $dh, $path) or do {
		warn "error opening directory: $path\n";
		return
	};
	my $git_dir = $path;
	if (is_git_dir($git_dir) || is_git_dir($git_dir .= '/.git')) {
		my $repo = { dir => $git_dir };
		cgit_repo_merge($self, $base, $repo);
		return;
	}
	while (defined(my $dn = readdir $dh)) {
		next if $dn eq '.' || $dn eq '..';
		if (index($dn, '.') == 0 && !$self->{-cgit_scan_hidden_path}) {
			next;
		}
		my $dir = "$path/$dn";
		scan_path_coderepo($self, $base, $dir) if -d $dir;
	}
	closedir $dh;
}

sub scan_tree_coderepo ($$) {
	my ($self, $path) = @_;
	scan_path_coderepo($self, $path, $path);
}

sub scan_projects_coderepo ($$) {
	my ($self, $path) = @_;
	my $l = $self->{-cgit_project_list} // die 'BUG: no cgit_project_list';
	open my $fh, '<', $l or do {
		warn "failed to open cgit project-list=$l: $!\n";
		return;
	};
	while (<$fh>) {
		chomp;
		scan_path_coderepo($self, $path, "$path/$_");
	}
}

sub apply_cgit_scan_path {
	my ($self, @paths) = @_;
	@paths or @paths = @{$self->{-cgit_scan_path}};
	if (defined($self->{-cgit_project_list})) {
		for my $p (@paths) { scan_projects_coderepo($self, $p) }
	} else {
		for my $p (@paths) { scan_tree_coderepo($self, $p) }
	}
}

sub parse_cgitrc {
	my ($self, $cgitrc, $nesting) = @_;
	$cgitrc //= $self->{'publicinbox.cgitrc'} //
			$ENV{CGIT_CONFIG} // return;
	if ($nesting == 0) {
		# defaults:
		my %s = map { $_ => 1 } qw(/cgit.css /cgit.png
						/favicon.ico /robots.txt);
		$self->{-cgit_static} = \%s;
	}

	# same limit as cgit/configfile.c::parse_configfile
	return if $nesting > 8;

	open my $fh, '<', $cgitrc or do {
		warn "failed to open cgitrc=$cgitrc: $!\n";
		return;
	};

	# FIXME: this doesn't support macro expansion via $VARS, yet
	my $repo;
	while (<$fh>) {
		chomp;
		if (m!\Arepo\.url=(.+?)/*\z!) {
			my $nick = $1;
			cgit_repo_merge($self, $repo->{dir}, $repo) if $repo;
			$repo = { url => $nick };
		} elsif (m!\Arepo\.path=(.+)\z!) {
			if (defined $repo) {
				$repo->{dir} = $1;
			} else {
				warn "$_ without repo.url\n";
			}
		} elsif (m!\Ainclude=(.+)\z!) {
			parse_cgitrc($self, $1, $nesting + 1);
		} elsif (m!\A(scan-hidden-path|remove-suffix)=([0-9]+)\z!) {
			my ($k, $v) = ($1, $2);
			$k =~ tr/-/_/;
			$self->{"-cgit_$k"} = $v;
		} elsif (m!\A(project-list|strict-export)=(.+)\z!) {
			my ($k, $v) = ($1, $2);
			$k =~ tr/-/_/;
			$self->{"-cgit_$k"} = $v;
			delete $self->{-cgit_scan_path} if $k eq 'project_list';
		} elsif (m!\Ascan-path=(.+)\z!) {
			# this depends on being after project-list in the
			# config file, just like cgit.c
			push @{$self->{-cgit_scan_path}}, $1;
			apply_cgit_scan_path($self, $1);
		} elsif (m!\A(?:css|favicon|logo|repo\.logo)=(/.+)\z!) {
			# absolute paths for static files via PublicInbox::Cgit
			$self->{-cgit_static}->{$1} = 1;
		} elsif (s!\Asnapshots=\s*!!) {
			$self->{'coderepo.snapshots'} = $_;
		}
	}
	cgit_repo_merge($self, $repo->{dir}, $repo) if $repo;
}

sub valid_dir ($$) {
	my $dir = get_1($_[0], $_[1]) // return;
	index($dir, "\n") < 0 ? $dir : do {
		warn "E: `$_[1]=$dir' must not contain `\\n'\n";
		undef;
	}
}

# parse a code repo, only git is supported at the moment
sub fill_coderepo {
	my ($self, $nick) = @_;
	my $pfx = "coderepo.$nick";
	my $git_dir = valid_dir($self, "$pfx.dir") // return;
	-e $git_dir // return;
	my $git = PublicInbox::Git->new($git_dir);
	if (defined(my $cgits = $self->{"$pfx.cgiturl"})) {
		$git->{cgit_url} = $cgits = _array($cgits);
		$self->{"$pfx.cgiturl"} = $cgits;
	}
	my %dedupe = ($nick => undef);
	($git->{nick}) = keys %dedupe;
	$git;
}

sub get_all {
	my ($self, $key) = @_;
	my $v = $self->{$key} // return;
	_array($v);
}

sub git_bool {
	my ($val) = $_[-1]; # $_[0] may be $self, or $val
	if ($val =~ /\A(?:false|no|off|[\-\+]?(?:0x)?0+)\z/i) {
		0;
	} elsif ($val =~ /\A(?:true|yes|on|[\-\+]?(?:0x)?[0-9]+)\z/i) {
		1;
	} else {
		undef;
	}
}

# abs_path resolves symlinks, so we want to avoid it if rel2abs
# is sufficient and doesn't leave "/.." or "/../"
sub rel2abs_collapsed {
	require File::Spec;
	my $p = File::Spec->rel2abs(@_);
	return $p if substr($p, -3, 3) ne '/..' && index($p, '/../') < 0;
	require Cwd;
	Cwd::abs_path($p);
}

sub get_1 {
	my ($self, $key) = @_;
	my $v = $self->{$key};
	return $v if !ref($v);
	warn "W: $key has multiple values, only using `$v->[-1]'\n";
	$v->[-1];
}

sub repo_objs {
	my ($self, $ibxish) = @_;
	$ibxish->{-repo_objs} // do {
		my $ibx_coderepos = $ibxish->{coderepo} // return;
		parse_cgitrc($self, undef, 0);
		my $coderepos = $self->{-coderepos};
		my @repo_objs;
		for my $nick (@$ibx_coderepos) {
			my @parts = split(m!/!, $nick);
			for (@parts) {
				@parts = () unless valid_foo_name($_);
			}
			unless (@parts) {
				warn "invalid coderepo name: `$nick'\n";
				next;
			}
			my $repo = $coderepos->{$nick} //=
						fill_coderepo($self, $nick);
			$repo ? push(@repo_objs, $repo) :
				warn("coderepo.$nick.dir unset\n");
		}
		if (scalar @repo_objs) {
			for (@repo_objs) {
				push @{$_->{ibx_names}}, $ibxish->{name};
			}
			$ibxish->{-repo_objs} = \@repo_objs;
		} else {
			delete $ibxish->{coderepo};
		}
	}
}

sub _fill_ibx {
	my ($self, $name) = @_;
	my $pfx = "publicinbox.$name";
	my $ibx = {};
	for my $k (qw(watch)) {
		my $v = $self->{"$pfx.$k"};
		$ibx->{$k} = $v if defined $v;
	}
	for my $k (qw(filter newsgroup replyto httpbackendmax feedmax
			indexlevel indexsequentialshard boost sortorder)) {
		my $v = get_1($self, "$pfx.$k") // next;
		$ibx->{$k} = $v;
	}

	# "mainrepo" is backwards compatibility:
	my $dir = $ibx->{inboxdir} = valid_dir($self, "$pfx.inboxdir") //
				valid_dir($self, "$pfx.mainrepo") // return;
	for my $k (qw(obfuscate)) {
		my $v = $self->{"$pfx.$k"} // next;
		if (defined(my $bval = git_bool($v))) {
			$ibx->{$k} = $bval;
		} else {
			warn "Ignoring $pfx.$k=$v in config, not boolean\n";
		}
	}
	# TODO: more arrays, we should support multi-value for
	# more things to encourage decentralization
	for my $k (qw(address altid nntpmirror imapmirror
			coderepo hide listid url
			infourl watchheader indexheader
			nntpserver imapserver pop3server)) {
		my $v = $self->{"$pfx.$k"} // next;
		$ibx->{$k} = _array($v);
	}

	return unless valid_foo_name($name, 'publicinbox');
	my %dedupe = ($name => undef);
	($ibx->{name}) = keys %dedupe; # used as a key everywhere
	$ibx->{-pi_cfg} = $self;
	$ibx = PublicInbox::Inbox->new($ibx);
	for (grep /\S/, @{$ibx->{address}}) {
		my $lc_addr = lc($_);
		$self->{-by_addr}->{$lc_addr} = $ibx;
		$self->{-no_obfuscate}->{$lc_addr} = 1;
	}
	# RFC2919 section 6 stipulates "case insensitive equality"
	for my $list_id (grep /\S/, @{$ibx->{listid} // []}) {
		$self->{-by_list_id}->{lc($list_id)} = $ibx;
	}
	if (defined(my $ngname = $ibx->{newsgroup})) {
		if (ref($ngname)) {
			delete $ibx->{newsgroup};
			warn 'multiple newsgroups not supported: '.
				join(', ', @$ngname). "\n";
		# Newsgroup name needs to be compatible with RFC 3977
		# wildmat-exact and RFC 3501 (IMAP) ATOM-CHAR.
		# Leave out a few chars likely to cause problems or conflicts:
		# '|', '<', '>', ';', '#', '$', '&',
		} elsif ($ngname =~ m![^A-Za-z0-9/_\.\-\~\@\+\=:]! ||
				$ngname eq '') {
			delete $ibx->{newsgroup};
			warn "newsgroup name invalid: `$ngname'\n";
		} else {
			%dedupe = (lc($ngname) => undef);
			my ($lc) = keys %dedupe;
			$ibx->{newsgroup} = $lc;
			warn <<EOM if $lc ne $ngname;
W: newsgroup=`$ngname' lowercased to `$lc'
EOM
			# PublicInbox::NNTPD does stricter ->nntp_usable
			# checks, keep this lean for startup speed
			my $cur = $self->{-by_newsgroup}->{$lc} //= $ibx;
			warn <<EOM if $cur != $ibx;
W: newsgroup=`$lc' is used by both `$cur->{name}' and `$ibx->{name}'
EOM
		}
	}
	unless (defined $ibx->{newsgroup}) { # for ->eidx_key
		my $abs = rel2abs_collapsed($dir);
		if ($abs ne $dir) {
			warn "W: `$dir' canonicalized to `$abs'\n";
			$ibx->{inboxdir} = $abs;
		}
	}
	$self->{-by_name}->{$name} = $ibx;
	if ($ibx->{obfuscate}) {
		$ibx->{-no_obfuscate} = $self->{-no_obfuscate};
		$ibx->{-no_obfuscate_re} = $self->{-no_obfuscate_re};
		fill_all($self); # noop to populate -no_obfuscate
	}
	if (my $es = ALL($self)) {
		require PublicInbox::Isearch;
		$ibx->{isrch} = PublicInbox::Isearch->new($ibx, $es);
	}
	my $cur = $self->{-by_eidx_key}->{my $ekey = $ibx->eidx_key} //= $ibx;
	$cur == $ibx or warn
		"W: `$ekey' used by both `$cur->{name}' and `$ibx->{name}'\n";
	$ibx;
}

sub _fill_ei ($$) {
	my ($self, $name) = @_;
	eval { require PublicInbox::ExtSearch } or return;
	my $pfx = "extindex.$name";
	my $d = valid_dir($self, "$pfx.topdir") // return;
	-d $d or return;
	my $es = PublicInbox::ExtSearch->new($d);
	for my $k (qw(indexlevel indexsequentialshard)) {
		my $v = get_1($self, "$pfx.$k") // next;
		$es->{$k} = $v;
	}
	for my $k (qw(coderepo hide url infourl indexheader altid)) {
		my $v = $self->{"$pfx.$k"} // next;
		$es->{$k} = _array($v);
	}
	return unless valid_foo_name($name, 'extindex');
	$es->{name} = $name;
	$es->load_extra_indexers($es); # extindex.*.{altid,indexheader}
	$es;
}

sub _fill_csrch ($$) {
	my ($self, $name) = @_; # "" is a valid name for cindex
	return if $name ne '' && !valid_foo_name($name, 'cindex');
	eval { require PublicInbox::CodeSearch } or return;
	my $pfx = "cindex.$name";
	my $d = valid_dir($self, "$pfx.topdir") // return;
	-d $d or return;
	my $csrch = PublicInbox::CodeSearch->new($d, $self);
	for my $k (qw(localprefix)) {
		my $v = $self->{"$pfx.$k"} // next;
		$csrch->{$k} = _array($v);
	}
	$csrch->{name} = $name;
	$csrch;
}

sub lookup_cindex ($$) {
	my ($self, $name) = @_;
	$self->{-csrch_by_name}->{$name} //= _fill_csrch($self, $name);
}

sub each_cindex {
	my ($self, $cb, @arg) = @_;
	my @csrch = map {
		lookup_cindex($self, substr($_, length('cindex.'))) // ()
	} grep(m!\Acindex\.[^\./]*\z!, @{$self->{-section_order}});
	if (ref($cb) eq 'CODE') {
		$cb->($_, @arg) for @csrch;
	} else { # string function
		$_->$cb(@arg) for @csrch;
	}
}

sub config_cmd {
	my ($self, $env, $opt) = @_;
	my $f = $self->{-f} // default_file();
	my @opt_c = @{$self->{-opt_c} // []};
	my @cmd = (git_exe, @opt_c, 'config');
	@opt_c ? tmp_cmd_opt($env, $opt) : push(@cmd, '-f', $f);
	\@cmd;
}

sub urlmatch {
	my $self = shift;
	my @bool = $_[0] eq '--bool' ? (shift) : ();
	my ($key, $url, $try_git) = @_;
	state $urlmatch_broken; # requires git 1.8.5
	return if $urlmatch_broken;
	my (%env, %opt);
	my $cmd = $self->config_cmd(\%env, \%opt);
	push @$cmd, @bool, qw(--includes -z --get-urlmatch), $key, $url;
	my $val = run_qx($cmd, \%env, \%opt);
	if ($?) {
		undef $val;
		if (@bool && ($? >> 8) == 128) { # not boolean
		} elsif (($? >> 8) != 1) {
			$urlmatch_broken = 1;
		} elsif ($try_git) { # n.b. this takes cwd into account
			$val = run_qx([$cmd->[0], 'config', @bool,
					qw(-z --get-urlmatch), $key, $url]);
			undef $val if $?;
		}
	}
	$? = 0; # don't influence lei exit status
	if (defined($val)) {
		local $/ = "\0";
		chomp $val;
		$val = git_bool($val) if @bool;
	}
	$val;
}

sub json {
	state $json;
	$json //= do {
		for my $mod (qw(Cpanel::JSON::XS JSON::MaybeXS JSON JSON::PP)) {
			eval "require $mod" or next;
			# ->ascii encodes non-ASCII to "\uXXXX"
			$json = $mod->new->ascii(1) and last;
		}
		$json;
	};
}

sub squote_maybe ($) {
	my ($val) = @_;
	if ($val =~ m{([^\w@\./,\%\+\-])}) {
		$val =~ s/(['!])/'\\$1'/g; # '!' for csh
		return "'$val'";
	}
	$val;
}

my %re_map = ( '*' => '[^/]*?', '?' => '[^/]',
		'/**' => '/.*', '**/' => '.*/', '/**/' => '(?:/.*?/|/)',
		'[' => '[', ']' => ']', ',' => ',' );

sub glob2re ($) {
	my ($re) = @_;
	my $p = '';
	my $in_bracket = 0;
	my $qm = 0;
	my $schema_host_port = '';

	# don't glob URL-looking things that look like IPv6
	if ($re =~ s!\A([a-z0-9\+]+://\[[a-f0-9\:]+\](?::[0-9]+)?/)!!i) {
		$schema_host_port = quotemeta $1; # "http://[::1]:1234"
	}
	my $changes = ($re =~ s!(/\*\*/|\A\*\*/|/\*\*\z|.)!
		$re_map{$p eq '\\' ? '' : do {
			if ($1 eq '[') { ++$in_bracket }
			elsif ($1 eq ']') { --$in_bracket }
			elsif ($1 eq ',') { ++$qm } # no change
			$p = $1;
		}} // do {
			$p = $1;
			($p eq '-' && $in_bracket) ? $p : (++$qm, "\Q$p")
		}!sge);
	# bashism (also supported by curl): {a,b,c} => (a|b|c)
	$changes += ($re =~ s/([^\\]*)\\\{([^,]*,[^\\]*)\\\}/
			(my $in_braces = $2) =~ tr!,!|!;
			$1."($in_braces)";
			/sge);
	($changes - $qm) ? $schema_host_port.$re : undef;
}

sub get_coderepo {
	my ($self, $nick) = @_;
	my $git = $self->{-coderepos}->{$nick} // do {
		defined($self->{-cgit_scan_path}) ? do {
			apply_cgit_scan_path($self);
			my $cr = fill_coderepo($self, $nick);
			$cr ? ($self->{-coderepos}->{$nick} = $cr) : undef;
		} : undef;
	};
	$git && -e $git->{git_dir} ? $git : undef;
}

1;
