#!perl -w
# Copyright (C) all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use v5.10.1;
use PublicInbox::TestCommon;
use PublicInbox::Config;
use File::Copy qw(cp);
use IO::Handle ();
require_git(2.6);
require_mods qw(json DBD::SQLite Xapian psgi);
use IO::Uncompress::Gunzip qw(gunzip);
require PublicInbox::WWW;
my ($ro_home, $cfg_path) = setup_public_inboxes;
my ($tmpdir, $for_destroy) = tmpdir;
my $home = "$tmpdir/home";
mkdir $home or BAIL_OUT $!;
mkdir "$home/.public-inbox" or BAIL_OUT $!;
my $pi_config = "$home/.public-inbox/config";
cp($cfg_path, $pi_config) or BAIL_OUT;
my $env = { HOME => $home };
my $m2t = create_inbox 'mid2tid', version => 2, indexlevel => 'basic', sub {
	my ($im, $ibx) = @_;
	for my $n (1..3) {
		$im->add(PublicInbox::Eml->new(<<EOM)) or xbail 'add';
Date: Fri, 02 Oct 1993 00:0$n:00 +0000
Message-ID: <t\@$n>
Subject: tid $n
From: x\@example.com
References: <a-mid\@b>

$n
EOM
		$im->add(PublicInbox::Eml->new(<<EOM)) or xbail 'add';
Date: Fri, 02 Oct 1993 00:0$n:00 +0000
Message-ID: <ut\@$n>
Subject: unrelated tid $n
From: x\@example.com
References: <b-mid\@b>

EOM
	}
};
{
	open my $cfgfh, '>>', $pi_config or BAIL_OUT;
	$cfgfh->autoflush(1);
	print $cfgfh <<EOM or BAIL_OUT;
[extindex "all"]
	topdir = $tmpdir/eidx
	url = http://bogus.example.com/all
[publicinbox]
	wwwlisting = all
	grokManifest = all
[publicinbox "m2t"]
	inboxdir = $m2t->{inboxdir}
	url = http://example.com/m2t
	address = $m2t->{-primary_address}
	sortorder = 2
[publicinbox "t1"]
	sortorder = 10
EOM
	close $cfgfh or xbail "close: $!";
}

run_script([qw(-extindex --all), "$tmpdir/eidx"], $env) or BAIL_OUT;
my $www = PublicInbox::WWW->new(PublicInbox::Config->new($pi_config));
my $client = sub {
	my ($cb) = @_;
	my $res = $cb->(GET('/all/'));
	is($res->code, 200, '/all/ good');
	$res = $cb->(GET('/all/new.atom', Host => 'usethis.example.com'));
	like($res->content, qr!http://usethis\.example\.com/!s,
		'Host: header respected in Atom feed');
	unlike($res->content, qr!http://bogus\.example\.com/!s,
		'default URL ignored with different host header');

	$res = $cb->(GET('/all/_/text/config/'));
	is($res->code, 200, '/text/config HTML');
	$res = $cb->(GET('/all/_/text/config/raw'));
	is($res->code, 200, '/text/config raw');
	my $f = "$tmpdir/extindex.config";
	open my $fh, '>', $f or xbail $!;
	print $fh $res->content or xbail $!;
	close $fh or xbail $!;
	my $cfg = PublicInbox::Config->git_config_dump($f);
	is($?, 0, 'no errors from git-config parsing');
	ok($cfg->{'extindex.all.topdir'}, 'extindex.topdir defined');

	$res = $cb->(GET('/all/all.mbox.gz'));
	is($res->code, 200, 'all.mbox.gz');

	$res = $cb->(GET('/'));
	like($res->content, qr!\Qhttp://bogus.example.com/all\E!,
		'/all listed');
	$res = $cb->(GET('/?q='));
	is($res->code, 200, 'no query means all inboxes');
	$res = $cb->(GET('/?q=nonexistent'));
	is($res->code, 404, 'no inboxes matched');
	unlike($res->content, qr!no inboxes, yet!,
		'we have inboxes, just no matches');

	$res = $cb->(GET('/'));
	my $c = $res->content;
	my $m2t_pos = index($c, '/m2t');
	my $t1_pos = index($c, '/t1');
	my $t2_pos = index($c, '/t2');
	ok($m2t_pos < $t1_pos,
		'm2t (sortorder=2) before t1 (sortorder=10)');
	ok($t1_pos < $t2_pos,
		't1 (sortorder=10) before t2 (no sortorder)');

	$res = $cb->(GET('/?o=-1'));
	is($res->code, 200, 'reverse listing (o=-1)');
	$c = $res->content;
	$m2t_pos = index($c, '/m2t');
	$t1_pos = index($c, '/t1');
	$t2_pos = index($c, '/t2');
	ok($t2_pos < $t1_pos && $t1_pos < $m2t_pos,
		'o=-1 reverses order: t2, t1, m2t');

	$res = $cb->(GET('/?r=1'));
	is($res->code, 200, 'relevance listing (r=1)');
	$c = $res->content;
	$m2t_pos = index($c, '/m2t');
	$t1_pos = index($c, '/t1');
	$t2_pos = index($c, '/t2');
	ok($m2t_pos < $t1_pos && $t1_pos < $t2_pos,
		'r=1 keeps sortorder tie-break: m2t, t1, t2');

	my $m = {};
	for my $pfx (qw(/m2t /t1 /t2), '') {
		$res = $cb->(GET($pfx.'/manifest.js.gz'));
		gunzip(\($res->content) => \(my $js));
		$m->{$pfx} = json_utf8->decode($js);
	}
	is_deeply([sort keys %{$m->{''}}],
		[ sort(keys %{$m->{'/m2t'}}, keys %{$m->{'/t1'}},
			keys %{$m->{'/t2'}}) ],
		'm2t + t1 + t2 = all');
	is_deeply([ sort keys %{$m->{'/t2'}} ], [ '/t2/git/0.git' ],
		't2 manifest');
	is_deeply([ sort keys %{$m->{'/t1'}} ], [ '/t1' ],
		't1 manifest');
	is_deeply([ sort keys %{$m->{'/m2t'}} ], [ '/m2t/git/0.git' ],
		'm2t manifest');

	# ensure ibx->{isrch}->{es}->over is used instead of ibx->over:
	$res = $cb->(POST("/m2t/t\@1/?q=dt:19931002000259..&x=m"));
	is($res->code, 200, 'hit on mid2tid query');
	$res = $cb->(POST("/m2t/t\@1/?q=dt:19931002000400..&x=m"));
	is($res->code, 404, '404 on out-of-range mid2tid query');
	$res = $cb->(POST("/m2t/t\@1/?q=s:unrelated&x=m"));
	is($res->code, 404, '404 on cross-thread search');


	for my $c (qw(new active)) {
		$res = $cb->(GET("/m2t/topics_$c.html"));
		is($res->code, 200, "topics_$c.html on basic v2");
		$res = $cb->(GET("/all/topics_$c.html"));
		is($res->code, 200, "topics_$c.html on extindex");
	}

	for my $name (qw(all m2t)) {
		$res = $cb->(GET("/$name/666/"));
		is $res->code, 404, "$name on short, non-existent msgid";
	}
};
test_psgi(sub { $www->call(@_) }, $client);
%$env = (%$env, TMPDIR => $tmpdir, PI_CONFIG => $pi_config);
test_httpd($env, $client);

done_testing;
