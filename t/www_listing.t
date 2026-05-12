#!perl -w
# Copyright (C) all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
# manifest.js.gz generation and grok-pull integration test
use v5.12; use PublicInbox::TestCommon;
use PublicInbox::Import;
use IO::Uncompress::Gunzip qw(gunzip);
require_mods qw(json URI::Escape psgi -httpd HTTP::Tiny);
my $curl = require_cmd 'curl';
require PublicInbox::WwwListing;
require PublicInbox::ManifestJsGz;
require PublicInbox::Git;
require PublicInbox::Config;
my $json = PublicInbox::Config::json();
use autodie qw(open close mkdir);


my ($tmpdir, $for_destroy) = tmpdir();
my $bare = PublicInbox::Git->new("$tmpdir/bare.git");
PublicInbox::Import::init_bare($bare->{git_dir});
is($bare->manifest_entry, undef, 'empty repo has no manifest entry');
{
	my $fi_data = './t/git.fast-import-data';
	open my $fh, '<', $fi_data;
	my $env = { GIT_DIR => $bare->{git_dir} };
	xsys_e [qw(git fast-import --quiet)], $env, { 0 => $fh };
}

like($bare->manifest_entry->{fingerprint}, qr/\A[a-f0-9]{40}\z/,
	'got fingerprint with non-empty repo');

sub tiny_test {
	my ($json, $host, $port, $html) = @_;
	my ($tmp, $res);
	my $http = HTTP::Tiny->new;
	if ($html) {
		$res = $http->get("http://$host:$port/");
		is($res->{status}, 200, 'got HTML listing');
		like($res->{content}, qr!</html>!si, 'listing looks like HTML');

		$res = $http->get("http://$host:$port/",
				{'Accept-Encoding'=>'gzip'});
		is($res->{status}, 200, 'got gzipped HTML listing');
		gunzip(\(delete $res->{content}) => \$tmp);
		like($tmp, qr!</html>!si, 'unzipped listing looks like HTML');
	}
	$res = $http->get("http://$host:$port/manifest.js.gz");
	is($res->{status}, 200, 'got manifest');
	gunzip(\(delete $res->{content}) => \$tmp);
	unlike($tmp, qr/"modified":\s*"/, 'modified is an integer');
	my $manifest = $json->decode($tmp);
	ok(my $clone = $manifest->{'/alt'}, '/alt in manifest');
	is($clone->{owner}, "lorelei \x{100}", 'owner set');
	is($clone->{reference}, '/bare', 'reference detected');
	is($clone->{description}, "we're \x{100}ll clones", 'description read');
	ok(my $bare = $manifest->{'/bare'}, '/bare in manifest');
	is($bare->{description}, 'Unnamed repository',
		'missing $GIT_DIR/description fallback');

	like($bare->{fingerprint}, qr/\A[a-f0-9]{40}\z/, 'fingerprint');
	is($clone->{fingerprint}, $bare->{fingerprint}, 'fingerprint matches');
	is(HTTP::Date::time2str($bare->{modified}),
		$res->{headers}->{'last-modified'},
		'modified field and Last-Modified header match');

	ok(my $v2epoch0 = $manifest->{'/v2/git/0.git'}, 'v2 epoch 0 appeared');
	like($v2epoch0->{description}, qr/ \[epoch 0\]\z/,
		'epoch 0 in description');
	ok(my $v2epoch1 = $manifest->{'/v2/git/1.git'}, 'v2 epoch 1 appeared');
	like($v2epoch1->{description}, qr/ \[epoch 1\]\z/,
		'epoch 1 in description');

	$res = $http->get("http://$host:$port/alt/description");
	is($res->{content}, "we're \xc4\x80ll clones\n", 'UTF-8 description')
		or diag explain($res);
}

my $td;
SKIP: {
	require_git_http_backend 1;
	my $err = "$tmpdir/stderr.log";
	my $out = "$tmpdir/stdout.log";
	my $alt = "$tmpdir/alt.git";
	my $cfgfile = "$tmpdir/config";
	my $v2 = "$tmpdir/v2";
	my $sock = tcp_server();
	my ($host, $port) = tcp_host_port($sock);
	my @clone = qw(git clone -q -s --bare);
	xsys_e @clone, $bare->{git_dir}, $alt;

	PublicInbox::Import::init_bare("$v2/all.git");
	for my $i (0..2) {
		xsys_e @clone, $alt, "$v2/git/$i.git";
	}
	open my $fh, '>', "$v2/inbox.lock";
	open $fh, '>', "$v2/description";
	print $fh "a v2 inbox\n";
	close $fh;

	open $fh, '>', "$alt/description";
	print $fh "we're \xc4\x80ll clones\n";
	close $fh;
	xsys_e 'git', "--git-dir=$alt", qw(config gitweb.owner),
		"lorelei \xc4\x80";
	open $fh, '>', $cfgfile;
	print $fh <<"";
[publicinbox "bare"]
	inboxdir = $bare->{git_dir}
	url = http://$host/bare
	address = bare\@example.com
[publicinbox "alt"]
	inboxdir = $alt
	url = http://$host/alt
	address = alt\@example.com
[publicinbox "v2"]
	inboxdir = $v2
	url = http://$host/v2
	address = v2\@example.com

	close $fh;

	my $env = { PI_CONFIG => $cfgfile };
	my $cmd = [ '-httpd', '-W0', "--stdout=$out", "--stderr=$err" ];
	my $psgi = "$tmpdir/pfx.psgi";
	{
		open my $psgi_fh, '>', $psgi;
		print $psgi_fh <<'EOM';
use PublicInbox::WWW;
use Plack::Builder;
my $www = PublicInbox::WWW->new;
builder {
	enable 'Head';
	mount '/pfx/' => sub { $www->call(@_) }
}
EOM
		close $psgi_fh;
	}

	# ensure prefixed mount full clones work:
	$td = start_script([@$cmd, $psgi], $env, { 3 => $sock });
	my $opt = { 2 => \(my $clone_err = '') };
	ok(run_script(['-clone', "http://$host:$port/pfx", "$tmpdir/pfx" ],
		undef, $opt), 'pfx clone w/pfx') or diag "clone_err=$clone_err";

	open my $mh, '<', "$tmpdir/pfx/manifest.js.gz";
	gunzip(\(do { local $/; <$mh> }) => \(my $mjs = ''));
	my $mf = $json->decode($mjs);
	is_deeply([sort keys %$mf], [ qw(/alt /bare /v2/git/0.git
					/v2/git/1.git /v2/git/2.git) ],
		'manifest saved');
	for (keys %$mf) { ok(-d "$tmpdir/pfx$_", "pfx/$_ cloned") }
	open my $desc, '<', "$tmpdir/pfx/v2/description";
	$desc = <$desc>;
	is($desc, "a v2 inbox\n", 'v2 description retrieved');

	$clone_err = '';
	ok(run_script(['-clone', '--include=*/alt',
			"http://$host:$port/pfx", "$tmpdir/incl" ],
		undef, $opt), 'clone w/include') or diag "clone_err=$clone_err";
	ok(-d "$tmpdir/incl/alt", 'alt cloned');
	ok(!-d "$tmpdir/incl/v2" && !-d "$tmpdir/incl/bare", 'only alt cloned');
	is(xqx([qw(git config -f), "$tmpdir/incl/alt/config", 'gitweb.owner']),
		"lorelei \xc4\x80\n", 'gitweb.owner set by -clone');

	$clone_err = '';
	ok(run_script(['-clone', '--dry-run',
			"http://$host:$port/pfx", "$tmpdir/dry-run" ],
		undef, $opt), 'clone --dry-run') or diag "clone_err=$clone_err";
	ok(!-d "$tmpdir/dry-run", 'nothing cloned with --dry-run');

	undef $td;

	open $mh, '<', "$tmpdir/incl/manifest.js.gz";
	gunzip(\(do { local $/; <$mh> }) => \($mjs = ''));
	$mf = $json->decode($mjs);
	is_deeply([keys %$mf], [ '/alt' ], 'excluded keys skipped in manifest');

	$td = start_script($cmd, $env, { 3 => $sock });

	my $local_mfest = "$tmpdir/local.manifest.js.gz";
	xsys_e [$curl, '-gsSfR', '-o', $local_mfest,
		"http://$host:$port/manifest.js.gz" ];
	xsys_e [$curl, '-vgsSfR', '-o', "$tmpdir/again.js.gz",
		'-z', $local_mfest, "http://$host:$port/manifest.js.gz" ],
		undef, { 2 => \(my $curl_err) };
	like $curl_err, qr! HTTP/1\.[012] 304 !sm,
		'got 304 response w/ If-Modified-Since';

	# default publicinboxGrokManifest match=domain default
	tiny_test($json, $host, $port);

	# normal full clone on /
	$clone_err = '';
	ok(run_script(['-clone', "http://$host:$port/", "$tmpdir/full" ],
		undef, $opt), 'full clone') or diag "clone_err=$clone_err";
	ok(-d "$tmpdir/full/$_", "$_ cloned") for qw(alt v2 bare);

	undef $td;

	open $fh, '>>', $cfgfile;
	print $fh <<"";
[publicinbox]
	wwwlisting = all

	close $fh;
	$td = start_script($cmd, $env, { 3 => $sock });
	undef $sock;
	tiny_test($json, $host, $port, 1);

	# test sortorder config
	undef $td;
	open $fh, '>>', $cfgfile;
	print $fh <<"";
[publicinbox "bare"]
	sortorder = 1
[publicinbox "v2"]
	sortorder = 2

	close $fh;
	my $sock_so = tcp_server();
	my ($host_so, $port_so) = tcp_host_port($sock_so);
	$td = start_script($cmd, $env, { 3 => $sock_so });
	{
		my $http = HTTP::Tiny->new;
		my $res = $http->get("http://$host_so:$port_so/");
		is($res->{status}, 200, 'got listing with sortorder');
		my $c = $res->{content};
		my $bare_pos = index($c, '/bare');
		my $v2_pos = index($c, '/v2');
		my $alt_pos = index($c, '/alt');
		ok($bare_pos < $v2_pos,
			'bare (sortorder=1) before v2 (sortorder=2)');
		ok($v2_pos < $alt_pos,
			'v2 (sortorder=2) before alt (no sortorder)');
	}

	# grok-pull sleeps a long while some places:
	# https://lore.kernel.org/tools/20211013110344.GA10632@dcvr/
	skip 'TEST_GROK unset', 12 unless $ENV{TEST_GROK};
	my $grok_pull = require_cmd('grok-pull', 1) or
		skip('grok-pull not available', 12);
	my ($grok_version) = (xqx([$grok_pull, "--version"])
			=~ /(\d+)\.(?:\d+)(?:\.(\d+))?/);
	$grok_version >= 2 or
		skip('grok-pull v2 or later not available', 12);
	my $grok_loglevel = $ENV{TEST_GROK_LOGLEVEL} // 'info';

	mkdir "$tmpdir/mirror";
	my $tail = tail_f("$tmpdir/grok.log");
	open $fh, '>', "$tmpdir/repos.conf";
	print $fh <<"";
[core]
toplevel = $tmpdir/mirror
manifest = $tmpdir/local-manifest.js.gz
log = $tmpdir/grok.log
loglevel = $grok_loglevel
[remote]
site = http://$host:$port
manifest = \${site}/manifest.js.gz
[pull]
[fsck]

	close $fh;
	xsys($grok_pull, '-c', "$tmpdir/repos.conf");
	is($? >> 8, 0, 'grok-pull exit code as expected');
	for (qw(alt bare v2/git/0.git v2/git/1.git v2/git/2.git)) {
		ok(-d "$tmpdir/mirror/$_", "grok-pull created $_");
	}

	# support per-inbox manifests, handy for v2:
	# /$INBOX/v2/manifest.js.gz
	open $fh, '>', "$tmpdir/per-inbox.conf";
	print $fh <<"";
[core]
toplevel = $tmpdir/per-inbox
manifest = $tmpdir/per-inbox-manifest.js.gz
log = $tmpdir/grok.log
loglevel = $grok_loglevel
[remote]
site = http://$host:$port
manifest = \${site}/v2/manifest.js.gz
[pull]
[fsck]

	close $fh;
	mkdir "$tmpdir/per-inbox";
	xsys($grok_pull, '-c', "$tmpdir/per-inbox.conf");
	is($? >> 8, 0, 'grok-pull exit code as expected');
	for (qw(v2/git/0.git v2/git/1.git v2/git/2.git)) {
		ok(-d "$tmpdir/per-inbox/$_", "grok-pull created $_");
	}
	$td->kill;
	$td->join;
	is($?, 0, 'no error in exited process');
	open $fh, '<', $err;
	my $eout = do { local $/; <$fh> };
	unlike($eout, qr/wide/i, 'no Wide character warnings');
	unlike($eout, qr/uninitialized/i, 'no uninitialized warnings');
}

done_testing();
