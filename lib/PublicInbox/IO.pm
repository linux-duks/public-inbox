# Copyright (C) all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>

# supports reaping of children tied to a pipe or socket
package PublicInbox::IO;
use v5.12;
use parent qw(IO::Handle Exporter);
use PublicInbox::DS qw(awaitpid);
our @EXPORT_OK = qw(poll_in read_all try_cat write_file my_gets my_bufread);
use Carp qw(croak);
use IO::Poll qw(POLLIN);
use Errno qw(EINTR EAGAIN);
use PublicInbox::OnDestroy;
# don't autodie in top-level for Perl 5.16.3 (and maybe newer versions)
# we have our own ->close, so we scope autodie into each sub

sub waitcb { # awaitpid callback
	my ($pid, $errref, $cb, @args) = @_;
	$$errref = $?; # sets .cerr for _close
	$cb->($pid, @args) if $cb; # may clobber $?
}

sub attach_pid {
	my ($io, $pid, @cb_arg) = @_;
	bless $io, __PACKAGE__;
	# we share $err (and not $self) with awaitpid to avoid a ref cycle
	my $e = \(my $err);
	${*$io}{pi_io_reap} = [ $PublicInbox::OnDestroy::fork_gen, $pid, $e ];
	awaitpid($pid, \&waitcb, $e, @cb_arg);
	$io;
}

sub attached_pid {
	my ($io) = @_;
	${${*$io}{pi_io_reap} // []}[1];
}

sub can_reap {
	my ($io) = @_;
	${${*$io}{pi_io_reap} // [-1]}[0] == $PublicInbox::OnDestroy::fork_gen;
}

# caller cares about error result if they call close explicitly
# reap->[2] may be set before this is called via waitcb
sub close {
	my ($io) = @_;
	my $ret = $io->SUPER::close;
	my $reap = delete ${*$io}{pi_io_reap};
	return $ret if ($reap->[0] // -1) != $PublicInbox::OnDestroy::fork_gen;
	if (defined ${$reap->[2]}) { # reap_pids already reaped asynchronously
		$? = ${$reap->[2]};
	} else { # wait synchronously
		my $w = awaitpid($reap->[1]);
	}
	$? ? '' : $ret;
}

sub DESTROY {
	my ($io) = @_;
	my $reap = delete ${*$io}{pi_io_reap};
	if (($reap->[0] // -1) == $PublicInbox::OnDestroy::fork_gen) {
		$io->SUPER::close;
		${$reap->[2]} // awaitpid($reap->[1]);
	}
	$io->SUPER::DESTROY;
}

sub write_file ($$@) { # mode, filename, LIST (for print)
	use autodie qw(open close);
	open(my $fh, shift, shift);
	print $fh @_;
	defined(wantarray) && !wantarray ? $fh : close $fh;
}

sub poll_in ($;$) {
	IO::Poll::_poll($_[1] // -1, fileno($_[0]), my $ev = POLLIN);
}

sub read_all ($;$$$) { # pass $len=0 to read until EOF for :utf8 handles
	use autodie qw(read);
	my ($io, $len, $bref, $off) = @_;
	$bref //= \(my $buf);
	$off //= 0;
	my $r = 0;
	if (my $left = $len //= -s $io) { # known size (binmode :raw/:unix)
		do { # retry for binmode :unix
			$r = read($io, $$bref, $left, $off += $r) or croak(
				"read($io) premature EOF ($left/$len remain)");
		} while ($left -= $r);
	} else { # read until EOF
		while (($r = read($io, $$bref, 65536, $off += $r))) {}
	}
	wantarray ? split(/^/sm, $$bref) : $$bref
}

sub try_cat ($) {
	my ($path) = @_;
	open(my $fh, '<', $path) or return '';
	read_all $fh;
}

# TODO: move existing HTTP/IMAP/NNTP/POP3 uses of rbuf here
# this does not return partial data; only a scalar ref on success,
# 0 on EOF, and undef on error.
sub my_bufread ($$) {
	my ($io, $len) = @_;
	my $rbuf = ${*$io}{pi_io_rbuf} //= \(my $new = '');
	my $left = $len - length($$rbuf);
	my $r;
	while ($left > 0) {
		$r = sysread($io, $$rbuf, $left, length($$rbuf));
		if ($r) {
			$left -= $r;
		} elsif (defined($r)) { # EOF
			return 0;
		} else {
			next if ($! == EAGAIN and poll_in($io));
			next if $! == EINTR; # may be set by sysread or poll_in
			return; # unrecoverable error
		}
	}
	my $no_pad = substr($$rbuf, 0, $len, '');
	delete(${*$io}{pi_io_rbuf}) if $$rbuf eq '';
	\$no_pad;
}

sub my_gets ($;$$) {
	my ($io, $delim, $nowait) = @_;
	my $rbuf = ${*$io}{pi_io_rbuf} //= \(my $new = '');
	$delim //= "\n";
	while (1) {
		if ((my $n = index($$rbuf, $delim)) >= 0) {
			my $ret = substr($$rbuf, 0, $n + length($delim), '');
			delete(${*$io}{pi_io_rbuf}) if $$rbuf eq '';
			return $ret;
		}
		my $r = sysread($io, $$rbuf, 65536, length($$rbuf));
		if (!defined($r)) {
			if ($! == EAGAIN) {
				return if $nowait;
				next if poll_in($io);
			}
			next if $! == EINTR; # may be set by sysread or poll_in
			return; # unrecoverable error
		} elsif ($r == 0) { # return whatever's left on EOF
			delete(${*$io}{pi_io_rbuf});
			return $$rbuf;
		} # else { continue
	}
}

sub has_rbuf {
	my ($io) = @_;
	defined(${*$io}{pi_io_rbuf});
}

1;
