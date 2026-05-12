# Copyright (C) all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
#
# Used by -nntpd for listen sockets
package PublicInbox::Listener;
use v5.12;
use parent 'PublicInbox::DS';
use PublicInbox::DS qw(now);
use Socket qw(SOL_SOCKET SO_KEEPALIVE IPPROTO_TCP TCP_NODELAY);
use IO::Handle;
use PublicInbox::Syscall qw(EPOLLIN EPOLLEXCLUSIVE);
use Errno qw(EAGAIN ECONNABORTED);
our $MULTI_ACCEPT = 0;

# Warn on transient errors, mostly resource limitations.
# EINTR would indicate the failure to set NonBlocking in systemd or similar
my %ERR_WARN = map {;
	eval("Errno::$_()") => $_
} qw(EMFILE ENFILE ENOBUFS ENOMEM EINTR);

sub new {
	my ($class, $s, $cb, $multi_accept) = @_;
	setsockopt($s, SOL_SOCKET, SO_KEEPALIVE, 1);
	setsockopt($s, IPPROTO_TCP, TCP_NODELAY, 1); # ignore errors on non-TCP
	my $self = bless { post_accept => $cb }, $class;
	$self->{multi_accept} = $multi_accept //= $MULTI_ACCEPT;
	$self->SUPER::new($s, EPOLLIN|EPOLLEXCLUSIVE);
}

sub event_step {
	my ($self) = @_;
	my $sock = $self->{sock} or return;
	my $n = $self->{multi_accept};
	do {
		if (my $addr = accept(my $c, $sock)) {
			IO::Handle::blocking($c, 0); # no accept4 :<
			# newer IO::Socket::SSL (tested 2.098) doesn't like
			# unblessed sockets on TLS handshake failures;
			# and plan to unify DS{rbuf} with {pi_io_rbuf}
			bless $c, 'PublicInbox::IO';
			eval { $self->{post_accept}->($c, $addr, $sock) };
			warn "E: $@\n" if $@;
		} elsif ($! == EAGAIN || $! == ECONNABORTED) {
			# EAGAIN is common and likely
			# ECONNABORTED is common with bad connections
			return;
		} elsif (my $sym = $ERR_WARN{int($!)}) {
			my $now = now;
			return if $now < ($self->{next_warn} //= 0);
			$self->{next_warn} = $now + 30;
			return warn "W: accept(".fileno($sock)."): $! ($sym)\n";
		} else {
			return warn "BUG?: accept(): $!\n";
		}
	} while ($n--);
}

1;
