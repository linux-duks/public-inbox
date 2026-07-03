# Copyright all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# "lei reindex" command to reindex everything in lei/store
package PublicInbox::LeiReindex;
use v5.12;
use autodie qw(pipe);
use PublicInbox::EOFpipe;

sub lei_reindex {
	my ($lei, @argv) = @_;
	my $sto = $lei->_lei_store or return $lei->fail('nothing indexed');
	$sto->write_prepare($lei);
	my $max = $sto->search->over(1)->max;
	$lei->qerr("# reindexing 1..$max");
	pipe(my $r, my $w);
	my @io = (@$lei{2, 'sock'}, $w);
	PublicInbox::EOFpipe->new($r, $lei->can('dclose'), $lei);
	$lei->event_step_init; # ensure Ctrl-C can stop reindex
	# FIXME: wq_io_do can still block:
	$sto->wq_io_do('reindex_range', \@io, 1, $max, $lei->long_reqid);
}

1;
