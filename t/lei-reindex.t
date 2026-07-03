#!perl -w
# Copyright (C) all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use v5.12; use PublicInbox::TestCommon;
require_mods(qw(lei));

test_lei(sub {
	ok(!lei('reindex'), 'reindex fails w/o store');
	like $lei_err, qr/nothing indexed/, "`nothing reindexed' noted";

	lei_ok qw(import t/data/0001.patch);
	lei_ok 'reindex', \'reindex successful after import';
});

done_testing;
