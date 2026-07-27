# Copyright (C) all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# internal APIs used only for tests
package PublicInbox::TestCommon;
use strict;
use parent qw(Exporter);
use v5.10.1;
use Fcntl qw(F_SETFD F_GETFD FD_CLOEXEC :seek);
use POSIX qw(dup2);
use IO::Socket::INET;
use File::Spec;
use Scalar::Util qw(isvstring);
use Carp ();
our @EXPORT;
my $lei_loud = $ENV{TEST_LEI_ERR_LOUD};
our $tail_cmd = $ENV{TAIL};
our ($lei_opt, $lei_out, $lei_err, $find_xh_pid);
use autodie qw(chdir close fcntl mkdir open opendir seek symlink unlink);
$ENV{XDG_CACHE_HOME} //= "$ENV{HOME}/.cache"; # reuse C++ xap_helper builds
$ENV{GIT_TEST_FSYNC} = 0; # hopefully reduce wear

$_ = File::Spec->rel2abs($_) for (grep(!m!^/!, @INC));
our ($CURRENT_DAEMON, $CURRENT_LISTENER);
BEGIN {
	@EXPORT = qw(tmpdir tcp_server tcp_connect require_git require_mods
		run_script start_script key2sub xsys xsys_e xqx eml_load tick
		have_xapian_compact json_utf8 setup_public_inboxes create_inbox
		create_dir
		create_coderepo require_bsd kernel_version check_broken_tmpfs
		quit_waiter_pipe wait_for_eof require_git_http_backend
		tcp_host_port test_lei lei lei_ok $lei_out $lei_err $lei_opt
		test_httpd no_httpd_errors xbail require_cmd is_xdeeply tail_f
		ignore_inline_c_missing no_coredump cfg_new
		require_fast_reliable_signals
		strace strace_inject lsof_pid oct_is $find_xh_pid
		block_size_arg xap_block_size);
	require Test::More;
	my @methods = grep(!/\W/, @Test::More::EXPORT);
	eval(join('', (map { "*$_=\\&Test::More::$_;" } @methods),
		'*TODO = \*Test::More::TODO;'));
	die $@ if $@;
	push @EXPORT, @methods, '$TODO';
}

sub kernel_version () {
	state $version = do {
		require POSIX;
		my @u = POSIX::uname();
		if ($u[2] =~ /\A([0-9]+(?:\.[0-9]+)+)/) {
			eval "v$1";
		} else {
			local $" = "', `";
			diag "Unable to get kernel version from: `@u'";
			undef;
		}
	};
}

sub check_broken_tmpfs () {
	return if $^O ne 'dragonfly' || kernel_version ge v6.5;
	diag 'EVFILT_VNODE + tmpfs is broken on dragonfly <= 6.4 (have: '.
		sprintf('%vd', kernel_version).')';
	1;
}

sub require_fast_reliable_signals (;$) {
	state $ok = !!(PublicInbox::Syscall->can('epoll_pwait') //
			eval { require IO::KQueue });
	return $ok if $ok || defined(wantarray);
	my $m = "fast, reliable signals not available(\$^O=$^O)";
	@_ ? skip($m, 1) : plan(skip_all => $m);
}

sub require_bsd (;$) {
	state $ok = ($^O =~ m!\A(?:free|net|open)bsd\z! ||
			$^O eq 'dragonfly');
	return 1 if $ok;
	return if defined(wantarray);
	my $m = "$0 is BSD-only (\$^O=$^O)";
	@_ ? skip($m, 1) : plan(skip_all => $m);
}

sub xbail (@) { BAIL_OUT join(' ', map { ref() ? (explain($_)) : ($_) } @_) }

sub read_all ($;$$$) {
	require PublicInbox::IO;
	PublicInbox::IO::read_all($_[0], $_[1], $_[2], $_[3])
}

sub eml_load ($) {
	my ($path, $cb) = @_;
	open(my $fh, '<', $path);
	require PublicInbox::Eml;
	PublicInbox::Eml->new(\(scalar read_all $fh));
}

sub tmpdir (;$) {
	my ($base) = @_;
	require File::Temp;
	($base) = ($0 =~ m!\b([^/]+)\.[^\.]+\z!) unless defined $base;
	($base) = ($0 =~ m!\b([^/]+)\z!) unless defined $base;
	my $tmpdir = File::Temp->newdir("pi-$base-$$-XXXX", TMPDIR => 1);
	wantarray ? ($tmpdir->dirname, $tmpdir) : $tmpdir;
}

sub tcp_server () {
	my %opt = (
		ReuseAddr => 1,
		Proto => 'tcp',
		Type => Socket::SOCK_STREAM(),
		Listen => 1024,
		Blocking => 0,
	);
	eval {
		die 'IPv4-only' if $ENV{TEST_IPV4_ONLY};
		my $pkg;
		for (qw(IO::Socket::IP IO::Socket::INET6)) {
			eval "require $_" or next;
			$pkg = $_ and last;
		}
		$pkg->new(%opt, LocalAddr => '[::1]');
	} || eval {
		die 'IPv6-only' if $ENV{TEST_IPV6_ONLY};
		IO::Socket::INET->new(%opt, LocalAddr => '127.0.0.1')
	} || BAIL_OUT "failed to create TCP server: $! ($@)";
}

sub tcp_host_port ($) {
	my ($s) = @_;
	my ($h, $p) = ($s->sockhost, $s->sockport);
	my $ipv4 = $s->sockdomain == Socket::AF_INET();
	if (wantarray) {
		$ipv4 ? ($h, $p) : ("[$h]", $p);
	} else {
		$ipv4 ? "$h:$p" : "[$h]:$p";
	}
}

sub tcp_connect {
	my ($dest, %opt) = @_;
	my $addr = tcp_host_port($dest);
	my $s = ref($dest)->new(
		Proto => 'tcp',
		Type => Socket::SOCK_STREAM(),
		PeerAddr => $addr,
		%opt,
	) or BAIL_OUT "failed to connect to $addr: $!";
	$s->autoflush(1);
	$s;
}

sub require_cmd ($;$) {
	my ($cmd, $nr) = @_;
	require PublicInbox::Spawn;
	state %CACHE;
	my $bin = $CACHE{$cmd} //= PublicInbox::Spawn::which($cmd);
	return $bin if $bin;
	return plan(skip_all => "$cmd missing from PATH for $0") if !$nr;
	defined(wantarray) ? undef : skip("$cmd missing", $nr);
}

sub have_xapian_compact (;$) {
	require_cmd($ENV{XAPIAN_COMPACT} || 'xapian-compact', @_ ? $_[0] : ());
}

sub require_git ($;$) {
	my ($req, $nr) = @_;
	require PublicInbox::Git;
	state $cur_vstr = PublicInbox::Git::git_version();
	$req = eval("v$req") unless isvstring($req);

	return 1 if $cur_vstr ge $req;
	state $cur_ver = sprintf('%vd', $cur_vstr);
	my $vreq = sprintf('%vd', $req);
	return plan skip_all => "git $vreq+ required, have $cur_ver" if !$nr;
	defined(wantarray) ? undef :
		skip("git $vreq+ required (have $cur_ver)", $nr)
}

sub require_git_http_backend (;$) {
	my ($nr) = @_;
	state $ok = do {
		my $rdr = { 1 => \my $out, 2 => \my $err };
		xsys([qw(git http-backend)], undef, $rdr);
		$out =~ /^Status:/ism;
	};
	if (!$ok) {
		my $msg = "`git http-backend' not available";
		defined($nr) ? skip $msg, $nr : plan skip_all => $msg;
	}
	$ok;
}

my %IPv6_VERSION = (
	'Net::NNTP' => 3.00,
	'Mail::IMAPClient' => 3.40,
	'HTTP::Tiny' => 0.042,
	'Net::POP3' => 2.32,
);

sub need_accept_filter ($) {
	my ($af) = @_;
	return if $^O eq 'netbsd'; # since NetBSD 5.0, no kldstat needed
	$^O =~ /\A(?:freebsd|dragonfly)\z/ or
		skip 'SO_ACCEPTFILTER is FreeBSD/NetBSD/Dragonfly-only so far',
			1;
	state $tried = {};
	($tried->{$af} //= system("kldstat -m $af >/dev/null")) and
		skip "$af not loaded: kldload $af", 1;
}

sub require_mods (@) {
	my @mods = @_;
	my $maybe = pop @mods if $mods[-1] =~ /\A[0-9]+\z/;
	my (@need, @use);

	while (my $mod = shift(@mods)) {
		if ($mod eq 'lei') {
			require_git(2.6, $maybe ? $maybe : ());
			push @mods, qw(DBD::SQLite Xapian +SCM_RIGHTS);
			$mod = 'json'; # fall-through
		}
		if ($mod eq 'v2') {
			require_git v2.6, $maybe ? $maybe : 0;
			push @mods, 'DBD::SQLite';
			next;
		} elsif ($mod =~ /\Av/) { # don't confuse with Perl versions
			Carp::croak "BUG: require_mods `$mod' ambiguous";
		}
		if ($mod eq 'json') {
			$mod = 'Cpanel::JSON::XS||JSON::MaybeXS||JSON||JSON::PP'
		} elsif ($mod eq '-httpd') {
			push @mods, qw(Plack::Builder Plack::Util
				HTTP::Date HTTP::Status);
			next;
		} elsif ($mod eq 'psgi') {
			my @m = qw(Plack::Test HTTP::Request::Common
				Plack::Builder);
			push @use, @m;
			push @mods, qw(Plack::Util), @m;
			next;
		} elsif ($mod eq '-imapd') {
			push @mods, qw(Parse::RecDescent DBD::SQLite);
			next;
		} elsif ($mod eq '-nntpd' || $mod eq 'v2') {
			push @mods, qw(DBD::SQLite);
			next;
		}
		if ($mod eq 'Xapian' || $mod eq 'SWIG-Xapian') {
			if (eval { require PublicInbox::Search } &&
					PublicInbox::Search::load_xapian()) {
				if ($mod eq 'SWIG-Xapian') {
					my $x = eval
						'$PublicInbox::Search::Xap';
					$x eq 'Xapian' or push @need,
						'SWIG Xapian bindings (not XS)';
				}
				next;
			}
		} elsif ($mod eq '+SCM_RIGHTS') {
			push @need, need_scm_rights();
			next;
		} elsif ($mod eq ':fcntl_lock') {
			next if $^O eq 'linux' || require_bsd;
			diag "untested platform: $^O, ".
				"requiring File::FcntlLock...";
			push @mods, 'File::FcntlLock';
		} elsif ($mod =~ /\A\+(accf_.*)\z/) {
			need_accept_filter($1);
			next
		} elsif (index($mod, '||') >= 0) { # "Foo||Bar"
			my $ok;
			for my $m (split(/\Q||\E/, $mod)) {
				eval "require $m";
				next if $@;
				$ok = $m;
				last;
			}
			next if $ok;
		} else {
			eval "require $mod";
		}
		if ($@) {
			diag "require $mod: $@" if $mod =~ /Lg2/;
			push @need, $mod;
		} elsif ($mod eq 'IO::Socket::SSL' &&
			# old versions of IO::Socket::SSL aren't supported
			# by libnet, at least:
			# https://rt.cpan.org/Ticket/Display.html?id=100529
				!eval{ IO::Socket::SSL->VERSION(2.007); 1 }) {
			push @need, $@;
		}
		if (defined(my $v = $IPv6_VERSION{$mod})) {
			$ENV{TEST_IPV4_ONLY} = 1 if !eval { $mod->VERSION($v) };
		}
	}
	unless (@need) {
		for my $mod (@use) {
			my ($pkg) = caller(0);
			eval "package $pkg; $mod->import";
			xbail "$mod->import: $@" if $@;
		}
		return;
	}
	my $m = join(', ', @need)." missing for $0";
	$m =~ s/\b(Email::MIME|Mail::Thread)\b/$1 (dev purposes only)/;
	skip($m, $maybe) if $maybe;
	plan(skip_all => $m)
}

sub key2script ($) {
	my ($key) = @_;
	require PublicInbox::Git;
	return PublicInbox::Git::git_exe() if $key eq 'git';
	return $key if index($key, '/') >= 0;
	# n.b. we may have scripts which don't start with "public-inbox" in
	# the future:
	$key =~ s/\A([-\.])/public-inbox$1/;
	'blib/script/'.$key;
}

my @io_mode = ([ \*STDIN, '+<&' ], [ \*STDOUT, '+>&' ], [ \*STDERR, '+>&' ]);

sub _prepare_redirects ($) {
	my ($fhref) = @_;
	my $orig_io = [];
	for (my $fd = 0; $fd <= $#io_mode; $fd++) {
		my $fh = $fhref->[$fd] or next;
		my ($oldfh, $mode) = @{$io_mode[$fd]};
		open(my $orig, $mode, $oldfh);
		$orig_io->[$fd] = $orig;
		open $oldfh, $mode, $fh;
	}
	$orig_io;
}

sub _undo_redirects ($) {
	my ($orig_io) = @_;
	for (my $fd = 0; $fd <= $#io_mode; $fd++) {
		my $fh = $orig_io->[$fd] or next;
		my ($oldfh, $mode) = @{$io_mode[$fd]};
		open $oldfh, $mode, $fh;
	}
}

# $opt->{run_mode} (or $ENV{TEST_RUN_MODE}) allows choosing between
# three ways to spawn our own short-lived Perl scripts for testing:
#
# 0 - (fork|vfork) + execve, the most realistic but slowest
# 1 - (not currently implemented)
# 2 - preloading and running in current process (slightly faster than 1)
#
# 2 is not compatible with scripts which use "exit" (which we'll try to
# avoid in the future).
# The default is 2.
our $run_script_exit_code;
sub RUN_SCRIPT_EXIT () { "RUN_SCRIPT_EXIT\n" };
sub run_script_exit {
	$run_script_exit_code = $_[0] // 0;
	die RUN_SCRIPT_EXIT;
}

our %cached_scripts;
sub key2sub ($) {
	my ($key) = @_;
	$cached_scripts{$key} //= do {
		my $f = key2script($key);
		open my $fh, '<', $f;
		my $str = read_all($fh);
		my $pkg = (split(m!/!, $f))[-1];
		$pkg =~ s/([a-z])([a-z0-9]+)(\.t)?\z/\U$1\E$2/;
		$pkg .= "_T" if $3;
		$pkg =~ tr/-.//d;
		my $tmpdir = tmpdir;
		my $pl = "$tmpdir/$pkg.pl";
		$pkg = "PublicInbox::TestScript::$pkg";
		require PublicInbox::IO;
		PublicInbox::IO::write_file('>', $pl, <<EOF);
package $pkg;
use strict;
use subs qw(exit);

*exit = \\&PublicInbox::TestCommon::run_script_exit;
sub main {
# the below "line" directive is a magic comment, see perlsyn(1) manpage
# line 1 "$f"
{ $str }
	0;
}
1;
EOF
		# `require' on a file gives us a new scope which
		# `eval' can't, so we do that to ensure we don't have
		# conflicting `use VERSION' statements which become fatal
		# in Perl v5.44 :<
		require $pl;
		$pkg->can('main');
	}
}

sub _run_sub ($$$) {
	my ($sub, $key, $argv) = @_;
	local @ARGV = @$argv;
	$run_script_exit_code = undef;
	my $exit_code = eval { $sub->(@$argv) };
	if ($@ eq RUN_SCRIPT_EXIT) {
		$@ = '';
		$exit_code = $run_script_exit_code;
		$? = ($exit_code << 8);
	} elsif (defined($exit_code)) {
		$? = ($exit_code << 8);
	} elsif ($@) { # mimic die() behavior when uncaught
		warn "E: eval-ed $key: $@\n";
		$? = ($! << 8) if $!;
		$? = (255 << 8) if $? == 0;
	} else {
		die "BUG: eval-ed $key: no exit code or \$@\n";
	}
}

sub no_coredump (@) {
	my @dirs = @_;
	my $cwdfh;
	opendir($cwdfh, '.') if @dirs;
	my @found;
	for (@dirs, '.') {
		chdir $_;
		my @cores = glob('core.* *.core');
		push @cores, 'core' if -d 'core';
		push(@found, "@cores found in $_") if @cores;
		chdir $cwdfh if $cwdfh;
	}
	return if !@found; # keep it quiet.
	is(scalar(@found), 0, 'no core dumps found');
	diag(join("\n", @found) . Carp::longmess());
	if (-t STDIN) {
		diag 'press ENTER to continue, (q) to quit';
		chomp(my $line = <STDIN>);
		xbail 'user quit' if $line =~ /\Aq/;
	}
}

sub run_script ($;$$) {
	my ($cmd, $env, $opt) = @_;
	no_coredump($opt->{-C} ? ($opt->{-C}) : ());
	my ($key, @argv) = @$cmd;
	my $run_mode = $ENV{TEST_RUN_MODE} // $opt->{run_mode} // 1;
	my $sub = $run_mode == 0 ? undef : key2sub($key);
	my $fhref = [];
	my $spawn_opt = {};
	my @tail_paths;
	local $tail_cmd = $tail_cmd;
	for my $fd (0..2) {
		my $redir = $opt->{$fd};
		my $ref = ref($redir);
		if ($ref eq 'SCALAR') {
			my $fh;
			if ($ENV{TAIL_ALL} && $fd > 0) {
				# tail -F is better, but not portable :<
				$tail_cmd //= 'tail -f';
				require File::Temp;
				$fh = File::Temp->new("fd.$fd-XXXX", TMPDIR=>1);
				push @tail_paths, $fh->filename;
			} else {
				open $fh, '+>', undef;
			}
			$fh or xbail $!;
			$fhref->[$fd] = $fh;
			$spawn_opt->{$fd} = $fh;
			next if $fd > 0;
			$fh->autoflush(1);
			print $fh $$redir or die "print: $!";
			seek($fh, 0, SEEK_SET);
		} elsif ($ref eq 'GLOB') {
			$spawn_opt->{$fd} = $fhref->[$fd] = $redir;
		} elsif ($ref) {
			die "unable to deal with $ref $redir";
		}
	}
	my $tail = @tail_paths ? tail_f(@tail_paths, $opt) : undef;
	if ($key =~ /-(index|cindex|extindex|convert|xcpdb)\z/) {
		unshift @argv, '--no-fsync';
	}
	if ($run_mode == 0) {
		# spawn an independent new process, like real-world use cases:
		require PublicInbox::Spawn;
		my $cmd = [ key2script($key), @argv ];
		if (my $d = $opt->{'-C'}) {
			$cmd->[0] = File::Spec->rel2abs($cmd->[0]);
			$spawn_opt->{'-C'} = $d;
		}
		PublicInbox::Spawn::run_wait($cmd, $env, $spawn_opt);
	} else { # localize and run everything in the same process:
		# note: "local *STDIN = *STDIN;" and so forth did not work in
		# old versions of perl
		my $umask = umask;
		local %ENV = $env ? (%ENV, %$env) : %ENV;
		local @SIG{keys %SIG} = map { undef } values %SIG;
		local $SIG{FPE} = 'IGNORE'; # Perl default
		local $0 = join(' ', @$cmd);
		my $orig_io = _prepare_redirects($fhref);
		opendir(my $cwdfh, '.');
		chdir $opt->{-C} if defined $opt->{-C};
		_run_sub($sub, $key, \@argv);
		# n.b. all our uses of PublicInbox::DS should be fine
		# with this and we can't Reset here.
		chdir($cwdfh);
		_undo_redirects($orig_io);
		select STDOUT;
		umask($umask);
	}

	{ local $?; undef $tail };
	# slurp the redirects back into user-supplied strings
	for my $fd (1..2) {
		my $fh = $fhref->[$fd] or next;
		next unless -f $fh;
		seek($fh, 0, SEEK_SET);
		${$opt->{$fd}} = read_all($fh);
	}
	no_coredump($opt->{-C} ? ($opt->{-C}) : ());
	$? == 0;
}

sub tick (;$) {
	my $tick = shift // 0.1;
	select undef, undef, undef, $tick;
	1;
}

sub wait_for_tail {
	my ($tail_pid, $want) = @_;
	my $wait = 2; # "tail -F" sleeps 1.0s at-a-time w/o inotify/kevent
	if ($^O eq 'linux') { # GNU tail may use inotify
		state $tail_has_inotify;
		return tick if !$want && $tail_has_inotify; # before TERM
		my $end = time + $wait; # wait for startup:
		my @ino;
		do {
			@ino = grep {
				(readlink($_) // '') =~ /\binotify\b/
			} glob("/proc/$tail_pid/fd/*");
		} while (!@ino && time <= $end and tick);
		return if !@ino;
		$tail_has_inotify = 1;
		$ino[0] =~ s!/fd/!/fdinfo/!;
		my @info;
		do {
			if (CORE::open(my $fh, '<', $ino[0])) {
				local $/ = "\n";
				@info = grep(/^inotify wd:/, <$fh>);
			}
		} while (scalar(@info) < $want && time <= $end and tick);
	} else {
		sleep($wait);
	}
}

# like system() built-in, but uses spawn() for env/rdr + vfork
sub xsys {
	my ($cmd, $env, $rdr) = @_;
	if (ref($cmd)) {
		$rdr ||= {};
	} else {
		$cmd = [ @_ ];
		$env = undef;
		$rdr = {};
	}
	run_script($cmd, $env, { %$rdr, run_mode => 0 });
	$? >> 8
}

sub xsys_e { # like "/bin/sh -e"
	xsys(@_) == 0 or
		BAIL_OUT (ref $_[0] ? "@{$_[0]}" : "@_"). " failed \$?=$?"
}

# like `backtick` or qx{} op, but uses spawn() for env/rdr + vfork
sub xqx {
	my ($cmd, $env, $rdr) = @_;
	$rdr //= {};
	run_script($cmd, $env, { %$rdr, run_mode => 0, 1 => \(my $out) });
	wantarray ? split(/^/m, $out) : $out;
}

sub tail_f (@) {
	my @f = grep(defined, @_);
	$tail_cmd or return; # "tail -F" or "tail -f"
	my $opt = (ref($f[-1]) eq 'HASH') ? pop(@f) : {};
	my $clofork = $opt->{-CLOFORK} // [];
	my @cfmap = map {
		my $fl = fcntl($_, F_GETFD, 0);
		fcntl($_, F_SETFD, $fl | FD_CLOEXEC) unless $fl & FD_CLOEXEC;
		($_, $fl);
	} @$clofork;
	for (@f) { open(my $fh, '>>', $_) };
	my $cmd = [ split(/ /, $tail_cmd), @f ];
	require PublicInbox::Spawn;
	my $pid = PublicInbox::Spawn::spawn($cmd, undef, { 1 => 2 });
	while (my ($io, $fl) = splice(@cfmap, 0, 2)) {
		fcntl($io, F_SETFD, $fl);
	}
	wait_for_tail($pid, scalar @f);
	require PublicInbox::AutoReap;
	PublicInbox::AutoReap->new($pid, \&wait_for_tail);
}

sub start_script {
	my ($cmd, $env, $opt) = @_;
	my ($key, @argv) = @$cmd;
	my $run_mode = $ENV{TEST_RUN_MODE} // $opt->{run_mode} // 2;
	my $sub = $run_mode == 0 ? undef : key2sub($key);
	my $tail;
	my @xh = split(/\s+/, $ENV{TEST_DAEMON_XH} // '');
	@xh = () if $key !~ /-(?:imapd|netd|httpd|pop3d|nntpd)\z/;
	push @argv, @xh;
	if ($tail_cmd) {
		my @paths;
		for (@argv) {
			next unless /\A--std(?:err|out)=(.+)\z/;
			push @paths, $1;
		}
		if ($opt) {
			for (1, 2) {
				my $f = $opt->{$_} or next;
				if (!ref($f)) {
					push @paths, $f;
				} elsif (ref($f) eq 'GLOB' && $^O eq 'linux') {
					my $fd = fileno($f);
					my $f = readlink "/proc/$$/fd/$fd";
					push @paths, $f if -e $f;
				}
			}
		}
		$tail = tail_f(@paths, $opt);
	}
	require PublicInbox::DS;
	my $oset = PublicInbox::DS::block_signals();
	require PublicInbox::OnDestroy;
	my $tmp_mask = PublicInbox::OnDestroy::all(
					\&PublicInbox::DS::sig_setmask, $oset);
	my $pid = PublicInbox::DS::fork_persist();
	if ($pid == 0) {
		close($_) for (@{delete($opt->{-CLOFORK}) // []});
		# pretend to be systemd (cf. sd_listen_fds(3))
		# 3 == SD_LISTEN_FDS_START
		my $fd;
		for ($fd = 0; $fd < 3 || defined($opt->{$fd}); $fd++) {
			my $io = $opt->{$fd} // next;
			my $old = fileno($io);
			if ($old == $fd) {
				fcntl($io, F_SETFD, 0);
			} else {
				dup2($old, $fd) // die "dup2($old, $fd): $!";
			}
		}
		%ENV = (%ENV, %$env) if $env;
		my $fds = $fd - 3;
		if ($fds > 0) {
			$ENV{LISTEN_PID} = $$;
			$ENV{LISTEN_FDS} = $fds;
		}
		if ($opt->{-C}) { chdir($opt->{-C}) }
		$0 = join(' ', @$cmd, @xh);
		local @SIG{keys %SIG} = map { undef } values %SIG;
		local $SIG{FPE} = 'IGNORE'; # Perl default
		undef $tmp_mask;
		if ($sub) {
			_run_sub($sub, $key, \@argv);
			POSIX::_exit($? >> 8);
		} else {
			exec(key2script($key), @argv);
			die "FAIL: ",join(' ', $key, @argv), ": $!\n";
		}
	}
	undef $tmp_mask;
	require PublicInbox::AutoReap;
	my $td = PublicInbox::AutoReap->new($pid);
	$td->{-extra} = $tail;
	$td;
}

# favor lei() or lei_ok() over $lei for new code
sub lei (@) {
	my ($cmd, $env, $xopt) = @_;
	$lei_out = $lei_err = '';
	if (!ref($cmd)) {
		($env, $xopt) = grep { (!defined) || ref } @_;
		$cmd = [ grep { defined && !ref } @_ ];
	}
	my $res = run_script(['lei', @$cmd], $env, $xopt // $lei_opt);
	if ($lei_err ne '') {
		if ($lei_err =~ /Use of uninitialized/ ||
			$lei_err =~ m!\bArgument .*? isn't numeric in !) {
			fail "lei_err=$lei_err";
		} else {
			diag "lei_err=$lei_err" if $lei_loud;
		}
	}
	$res;
};

sub lei_ok (@) {
	state $PWD = $ENV{PWD} // Cwd::getcwd();
	my $msg = ref($_[-1]) eq 'SCALAR' ? pop(@_) : undef;
	my $tmpdir = quotemeta(File::Spec->tmpdir);
	# filter out anything that looks like a path name for consistent logs
	my @msg = ref($_[0]) eq 'ARRAY' ? @{$_[0]} : @_;
	if (!$lei_loud) {
		for (@msg) {
			s!(127\.0\.0\.1|\[::1\]):(?:\d+)!$1:\$PORT!g;
			s!$tmpdir\b/(?:[^/]+/)?!\$TMPDIR/!g;
			s!\Q$PWD\E\b!\$PWD!g;
		}
	}
	ok(lei(@_), "lei @msg". ($msg ? " ($$msg)" : '')) or
		diag "\$?=$? err=$lei_err";
}

sub json_utf8 () {
	state $x = ref(PublicInbox::Config->json)->new->utf8->canonical;
}

sub is_xdeeply ($$$) {
	my ($x, $y, $desc) = @_;
	my $ok = is_deeply($x, $y, $desc);
	diag explain([$x, '!=', $y]) if !$ok;
	$ok;
}

sub ignore_inline_c_missing {
	$_[0] = join('', grep(/\S/, grep(!/compilation aborted/,
		grep(!/\bInline\b/, split(/^/m, $_[0])))));
}

sub need_scm_rights () {
	state $ok = do {
			require PublicInbox::Syscall;
			PublicInbox::Syscall->can('send_cmd4'); # Linux+*BSD
		} || PublicInbox::Spawn->can('send_cmd4');
	return () if $ok;
	('need SCM_RIGHTS support: ' .
	 '(syscall numbers + msg_hdr pack templates missing) OR ' .
	 'Inline::C unconfigured/missing '.
	 '( mkdir -p ~/.cache/public-inbox/inline-c)' );
}

# returns a pipe with FD_CLOEXEC disabled on the write-end
sub quit_waiter_pipe () {
	pipe(my $r, my $w);
	fcntl($w, F_SETFD, fcntl($w, F_GETFD, 0) & ~FD_CLOEXEC);
	($r, $w);
}

sub wait_for_eof ($$;$) {
	my ($io, $msg, $sec) = @_;
	vec(my $rset = '', fileno($io), 1) = 1;
	ok(select($rset, undef, undef, $sec // 9), "$msg (select)");
	is(my $line = <$io>, undef, "$msg EOF");
}

sub test_lei {
SKIP: {
	my ($cb) = pop @_;
	my $test_opt = shift // {};
	require_git(2.6, 1);
	my $mods = $test_opt->{mods} // [ 'lei' ];
	require_mods(@$mods, 2);

	# set PERL_INLINE_DIRECTORY before clobbering XDG_CACHE_HOME
	require PublicInbox::Spawn;
	require PublicInbox::Config;
	require File::Path;
	state $xh_cmd = eval { # use XDG_CACHE_HOME, first:
		require PublicInbox::XapHelperCxx;
		PublicInbox::XapHelperCxx::cmd();
	};
	local %ENV = %ENV;
	delete $ENV{XDG_DATA_HOME};
	delete $ENV{XDG_CONFIG_HOME};
	delete $ENV{XDG_CACHE_HOME};
	$ENV{GIT_COMMITTER_EMAIL} = 'lei@example.com';
	$ENV{GIT_COMMITTER_NAME} = 'lei user';
	$ENV{LANG} = $ENV{LC_ALL} = 'C';
	my (undef, $fn, $lineno) = caller(0);
	my $t = "$fn:$lineno";
	$lei_opt = { 1 => \$lei_out, 2 => \$lei_err };
	my ($daemon_pid, $for_destroy, $daemon_xrd);
	my $tmpdir = $test_opt->{tmpdir};
	File::Path::mkpath($tmpdir) if defined $tmpdir;
	($tmpdir, $for_destroy) = tmpdir unless $tmpdir;
	my ($dead_r, $dead_w);
	state $persist_xrd = $ENV{TEST_LEI_DAEMON_PERSIST_DIR};
	SKIP: {
		$ENV{TEST_LEI_ONESHOT} and
			xbail 'TEST_LEI_ONESHOT no longer supported';
		my $home = "$tmpdir/lei-daemon";
		mkdir($home, 0700);
		local $ENV{HOME} = $home;
		if ($xh_cmd && $xh_cmd->[0] =~ m!\A(.+/+([^/]+))/+[^/]+\z!) {
			# avoid repeated rebuilds by symlinking entire dir
			my ($src, $bn) = ($1, $2);
			my $dst = "$home/.cache/public-inbox/jaot";
			File::Path::make_path($dst);
			symlink $src, "$dst/$bn";
		}
		my $persist;
		if ($persist_xrd && !$test_opt->{daemon_only}) {
			$persist = $daemon_xrd = $persist_xrd;
		} else {
			$daemon_xrd = "$home/xdg_run";
			mkdir($daemon_xrd, 0700);
			($dead_r, $dead_w) = quit_waiter_pipe;
		}
		local $ENV{XDG_RUNTIME_DIR} = $daemon_xrd;
		$cb->(); # likely shares $dead_w with lei-daemon
		undef $dead_w; # so select() wakes up when daemon dies
		if ($persist) { # remove before ~/.local gets removed
			File::Path::rmtree([glob("$home/*")]);
			File::Path::rmtree("$home/.config");
		} else {
			no_coredump $tmpdir;
			lei_ok(qw(daemon-pid), \"daemon-pid after $t");
			chomp($daemon_pid = $lei_out);
			if (!$daemon_pid) {
				fail("daemon not running after $t");
				skip 'daemon died unexpectedly', 2;
			}
			ok(kill(0, $daemon_pid), "daemon running after $t");
			lei_ok(qw(daemon-kill), \"daemon-kill after $t");
		}
	}; # SKIP for lei_daemon
	if ($daemon_pid) {
		wait_for_eof($dead_r, 'daemon quit pipe');
		no_coredump $tmpdir;
		my $f = "$daemon_xrd/lei/errors.log";
		open my $fh, '<', $f;
		my @l = <$fh>;
		is_xdeeply(\@l, [],
			"$t daemon XDG_RUNTIME_DIR/lei/errors.log empty");
	}
}; # SKIP if missing git 2.6+ || Xapian || SQLite || json
} # /test_lei

# returns the pathname to a ~/.public-inbox/config in scalar context,
# ($test_home, $pi_config_pathname) in list context
sub setup_public_inboxes () {
	my $test_home = "t/home2";
	my $pi_config = "$test_home/.public-inbox/config";
	my $stamp = "$test_home/setup-stamp";
	my @ret = ($test_home, $pi_config);
	return @ret if -f $stamp;

	require PublicInbox::Lock;
	my $lk = PublicInbox::Lock->new("$test_home/setup.lock");
	my $end = $lk->lock_for_scope;
	return @ret if -f $stamp;

	local $ENV{PI_CONFIG} = $pi_config;
	for my $V (1, 2) {
		run_script([qw(-init --skip-docdata), "-V$V",
				'--newsgroup', "t.v$V", "t$V",
				"$test_home/t$V", "http://example.com/t$V",
				"t$V\@example.com" ]) or xbail "init v$V";
		unlink "$test_home/t$V/description";
	}
	require PublicInbox::Config;
	require PublicInbox::InboxWritable;
	my $cfg = PublicInbox::Config->new;
	my $seen = 0;
	$cfg->each_inbox(sub {
		my ($ibx) = @_;
		my $im = PublicInbox::InboxWritable->new($ibx)->importer(0);
		my $V = $ibx->version;
		my @eml = (glob('t/*.eml'), 't/data/0001.patch');
		for (@eml) {
			next if $_ eq 't/psgi_v2-old.eml'; # dup mid
			$im->add(eml_load($_)) or BAIL_OUT "v$V add $_";
			$seen++;
		}
		$im->done;
	});
	$seen or BAIL_OUT 'no imports';
	open my $fh, '>', $stamp;
	@ret;
}

our %COMMIT_ENV = (
	GIT_AUTHOR_NAME => 'A U Thor',
	GIT_COMMITTER_NAME => 'C O Mitter',
	GIT_AUTHOR_EMAIL => 'a@example.com',
	GIT_COMMITTER_EMAIL => 'c@example.com',
);

# for memoizing based on coderefs and various create_* params
sub my_sum {
	require PublicInbox::SHA;
	require Data::Dumper;
	my $d = Data::Dumper->new(\@_);
	$d->$_(1) for qw(Deparse Sortkeys Terse);
	my @l = split /\n/s, $d->Dump;
	@l = grep !/\$\^H\{.+?[A-Z]+\(0x[0-9a-f]+\)/, @l; # autodie addresses
	my @addr = grep /[A-Za-z]+\(0x[0-9a-f]+\)/, @l;
	xbail 'undumpable addresses: ', \@addr if @addr;
	substr PublicInbox::SHA::sha256_hex(join('', @l)), 0, 8;
}

sub create_dir (@) {
	my ($ident, $cb) = (shift, pop);
	my %opt = @_;
	require PublicInbox::Lock;
	require PublicInbox::Import;
	my $tmpdir = delete $opt{tmpdir};
	my ($base) = ($0 =~ m!\b([^/]+)\.[^\.]+\z!);
	my $dir = "t/data-gen/$base.$ident-".my_sum($cb, \%opt);
	require File::Path;
	my $new = File::Path::make_path($dir);
	my $lk = PublicInbox::Lock->new("$dir/creat.lock");
	my $scope = $lk->lock_for_scope;
	if (!-f "$dir/creat.stamp") {
		opendir(my $cwd, '.');
		chdir($dir);
		local %ENV = (%ENV, %COMMIT_ENV);
		$cb->($dir);
		chdir($cwd); # some $cb chdir around
		open my $s, '>', "$dir/creat.stamp";
	}
	return $dir if !defined($tmpdir);
	xsys_e([qw(/bin/cp -Rp), $dir, $tmpdir]);
	$tmpdir;
}

sub create_coderepo (@) {
	my $ident = shift;
	require PublicInbox::Import;
	my ($db) = (PublicInbox::Import::default_branch() =~ m!([^/]+)\z!);
	create_dir "$ident-$db", @_;
}

sub create_inbox ($;@) {
	my $ident = shift;
	my $cb = pop;
	my %opt = @_;
	require PublicInbox::Lock;
	require PublicInbox::InboxWritable;
	require PublicInbox::Import;
	my ($base) = ($0 =~ m!\b([^/]+)\.[^\.]+\z!);
	my ($db) = (PublicInbox::Import::default_branch() =~ m!([^/]+)\z!);
	my $tmpdir = delete $opt{tmpdir};
	my $dir = "t/data-gen/$base.$ident-".my_sum($db, $cb, \%opt);
	require File::Path;
	my $new = File::Path::make_path($dir);
	my $lk = PublicInbox::Lock->new("$dir/creat.lock");
	$opt{inboxdir} = File::Spec->rel2abs($dir);
	$opt{name} //= $ident;
	my $scope = $lk->lock_for_scope;
	my $pre_cb = delete $opt{pre_cb};
	$pre_cb->($dir) if $pre_cb && $new;
	my $no_gc = delete $opt{-no_gc};
	my $addr = $opt{address} // [];
	$opt{-primary_address} //= $addr->[0] // "$ident\@example.com";
	my $parallel = delete($opt{importer_parallel}) // 0;
	my $creat_opt = { nproc => delete($opt{nproc}) // 1 };
	$creat_opt->{wal} = 1 if delete $opt{wal};
	my $ibx = PublicInbox::InboxWritable->new({ %opt }, $creat_opt);
	if (!-f "$dir/creat.stamp") {
		my $im = $ibx->importer($parallel);
		$cb->($im, $ibx);
		$im->done if $im;
		unless ($no_gc) {
			my @to_gc = $ibx->version == 1 ? ($ibx->{inboxdir}) :
					glob("$ibx->{inboxdir}/git/*.git");
			for my $dir (@to_gc) {
				xsys_e([ qw(git gc -q) ], { GIT_DIR => $dir });
			}
		}
		open my $s, '>', "$dir/creat.stamp";
	}
	if ($tmpdir) {
		undef $ibx;
		xsys([qw(/bin/cp -Rp), $dir, $tmpdir]) == 0 or
			BAIL_OUT "cp $dir $tmpdir";
		$opt{inboxdir} = $tmpdir;
		$ibx = PublicInbox::InboxWritable->new(\%opt);
	}
	$ibx;
}

sub no_httpd_errors ($;$) {
	my ($err, $msg) = @_;
	open my $fh, '<', $err;
	my $e = read_all $fh;
	$e =~ s/^Plack::Middleware::ReverseProxy missing,\n//gms and
		$e =~ s/^URL generation for redirects[^\n]*\n//gms;
	$e =~ s/^W: .*?try `kldload[^\n]+\n//gms;
	is $e, '', $msg // 'no httpd errors';
}

sub test_httpd ($$;$$) {
	my ($env, $client, $skip, $cb) = @_;
	my ($tmpdir, $for_destroy);
	my $psgi = delete $env->{psgi_file};
	if (!defined $psgi) {
		for (qw(PI_CONFIG)) { $env->{$_} or BAIL_OUT "$_ unset" }
	}
	$env->{TMPDIR} //= do {
		($tmpdir, $for_destroy) = tmpdir();
		$tmpdir;
	};
	SKIP: {
		require_mods qw(Plack::Test::ExternalServer LWP::UserAgent
				-httpd), $skip // 1;
		my $sock = tcp_server() or die;
		my ($out, $err) = map { "$env->{TMPDIR}/std$_.log" } qw(out err);
		my $cmd = [ qw(-httpd -W0), "--stdout=$out", "--stderr=$err" ];
		push @$cmd, $psgi if defined $psgi;
		my $td = start_script($cmd, $env, { 3 => $sock });
		my ($h, $p) = tcp_host_port($sock);
		local $ENV{PLACK_TEST_EXTERNALSERVER_URI} = "http://$h:$p";
		my $ua = LWP::UserAgent->new;
		$ua->max_redirect(0);
		local $CURRENT_DAEMON = $td;
		local $CURRENT_LISTENER = $sock;
		Plack::Test::ExternalServer::test_psgi(client => $client,
							ua => $ua);
		$cb->() if $cb;
		$td->join('TERM');
		no_httpd_errors $err;
	}
};

sub block_size_arg (;$) {
	my @bs;
	SKIP: {
		require_mods qw(SWIG-Xapian), 1;
		@bs = ('--block-size='.($_[0] ? $_[0] : '64k'));
	}
	@bs;
}

sub xap_block_size ($) {
	my ($dir) = @_;
	state $ck = require_cmd 'xapian-check', 1;
	$ck or skip 'xapian-check missing', 1;
	my $out = xqx([$ck, $dir]);
	$out =~ /\bblocksize=([0-9]+)K/ or
		skip "no blocksize reported by `$ck $dir':\n", $out;
	$1 * 1024;
}

# TODO: support fstat(1) on OpenBSD, lsof already works on FreeBSD + Linux
# don't use this for deleted file checks, we only check that on Linux atm
# and we can readlink /proc/PID/fd/* directly
sub lsof_pid ($;$) {
	my ($pid, $rdr) = @_;
	state $lsof = require_cmd('lsof', 1);
	$lsof or skip 'lsof missing/broken', 1;
	my @out = xqx([$lsof, '-p', $pid], undef, $rdr);
	if ($?) {
		undef $lsof;
		skip "lsof -p PID broken \$?=$?", 1;
	}
	my @cols = split ' ', $out[0];
	if (($cols[7] // '') eq 'NODE') { # normal lsof
		@out;
	} else { # busybox lsof ignores -p, so we DIY it
		grep /\b$pid\b/, @out;
	}
}

sub cfg_new ($;@) {
	my ($tmpdir, @body) = @_;
	require PublicInbox::Config;
	my $f = "$tmpdir/tmp_cfg";
	open my $fh, '>', $f;
	print $fh @body;
	close $fh;
	PublicInbox::Config->new($f);
}

our $strace_cmd;
sub strace (@) {
	my ($for_daemon) = @_;
	skip 'linux only test', 1 if $^O ne 'linux';
	if ($for_daemon) {
		my $f = '/proc/sys/kernel/yama/ptrace_scope';
		# TODO: we could fiddle with prctl in the daemon to make
		# things work, but I'm not sure it's worth it...
		state $ps = do {
			my $fh;
			CORE::open($fh, '<', $f) ? readline($fh) : 0;
		};
		chomp $ps;
		skip "strace unusable on existing PIDs\n$f is `$ps' (!= 0)", 1 if $ps;
	}
	require_cmd('strace', 1) or skip 'strace not available', 1;
}

sub strace_inject (;$) {
	my $cmd = strace(@_);
	state $ver = do {
		require PublicInbox::Spawn;
		my $v = PublicInbox::Spawn::run_qx([$cmd, '-V']);
		$v =~ m!version\s+([1-9]+\.[0-9]+)! or
				xbail "no strace -V: $v";
		eval("v$1");
	};
	$ver ge v4.16 or skip "$cmd too old for syscall injection (".
				sprintf('v%vd', $ver). ' < v4.16)', 1;
	$cmd
}

sub oct_is ($$$) {
	my ($got, $exp, $msg) = @_;
	@_ = (sprintf('0%03o', $got), sprintf('0%03o', $exp), $msg);
	goto &is; # tail recursion to get lineno from callers on failure
}

$find_xh_pid = $^O eq 'linux' && -r "/proc/$$/stat" ? sub {
	my ($ppid) = @_;
	my ($cmdline, $fh, @s);
	for (glob('/proc/*/stat')) {
		CORE::open $fh, '<', $_ or next;
		@s = split /\s+/, readline($fh) // next;
		next if $s[3] ne $ppid; # look for matching PPID
		CORE::open $fh, '<', "/proc/$s[0]/cmdline" or next;
		$cmdline = readline($fh) // next;
		if ($cmdline =~ /\0-MPublicInbox::XapHelper\0-e\0/ ||
				$cmdline =~ m!/xap_helper\0!) {
			return $s[0];
		}
	}
	undef;
} : 'xap_helper PID lookup currently depends on Linux /proc';

package PublicInbox::TestCommon::InboxWakeup;
use strict;
sub on_inbox_unlock { ${$_[0]}->($_[1]) }

1;
