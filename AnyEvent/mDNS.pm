package AnyEvent::mDNS;

use strict;
use 5.008_001;
our $VERSION = '0.05';

use AnyEvent 4.84;
use AnyEvent::DNS;
use AnyEvent::Handle;
use AnyEvent::Socket ();
use Socket;

sub discover($%) { ## no critic
    my $cb = sub {};
    $cb = pop if @_ % 2 == 0;

    my($proto, %args) = @_;

    my $fqdn = "$proto.local";
    my $data = AnyEvent::DNS::dns_pack { rd => 1, qd => [[$fqdn, "ptr"]] };

    my($name, $alias, $udp_proto) = AnyEvent::Socket::getprotobyname('udp');
    socket my($sock), PF_INET, SOCK_DGRAM, $udp_proto;
    AnyEvent::Util::fh_nonblocking $sock, 1;
    bind $sock, sockaddr_in(0, Socket::inet_aton('0.0.0.0'))
        or ($args{on_error} || sub { die @_ })->($!);

    my %found;
    my $callback = $args{on_found} || sub {};

    my $t; $t = AnyEvent::Handle->new(
        fh => $sock,
        timeout => $args{timeout} || 3,
        on_timeout => sub {
            undef $t;
            $cb->(values %found);
        },
        on_read => sub {
            my $handle = shift;
            my $buf = delete $handle->{rbuf};
            my $res = AnyEvent::DNS::dns_unpack $buf;

            my %service;
            $service{'proto'} = $proto;
            foreach my $rec (@{ $res->{an} }) {
                my $type = $rec->[1];

                ($type eq 'ptr') && do {
                    if (lc($rec->[0]) eq $fqdn) {
                        $service{'fullname'} = $service{'name'} = $rec->[3];
                        $service{'name'} =~ s/\.$fqdn$//;
                    }
                  next;
                };
                ($type eq 'srv') && do {
                    $service{'host'} = $rec->[6];
                    $service{'port'} = $rec->[5];
                    next;
                };
                ($type eq 'txt') && do {
                    push @{$service{'txt'}}, @$rec[3..$#$rec] if $rec->[3];
                    next;
                };
                ($type eq 'aaaa') && do {
                    $service{'ipv6'} = $rec->[3];
                    next;
                };
                ($type eq 'a') && do {
                    $service{'ip'} = $rec->[3];
                    next;
                };
            }

            if ($service{'name'} && $service{'host'}) {
                $found{$service{'fullname'}} ||= do {
                    $callback->(\%service) if $callback;
                    \%service;
                };
            }
        },
    );

    send $sock, $data, 0, sockaddr_in(5353, Socket::inet_aton('224.0.0.251'));
    defined wantarray && AnyEvent::Util::guard { undef $t };
}

1;
__END__

=encoding utf-8

=for stopwords
AnyEvent multicast DNS UDP mDNS

=head1 NAME

AnyEvent::mDNS - Multicast DNS in AnyEvent style

=head1 SYNOPSIS

  use AnyEvent::mDNS;

  my $cv = AnyEvent->condvar;

  AnyEvent::mDNS::discover '_http._tcp', $cv;

  my @services = $cv->recv;
  for my $service (@_) {
      warn "Found $service->{name} ($service->{proto}) running on $service->{host}:$service->{port}\n";
  }

=head1 DESCRIPTION

AnyEvent::mDNS is a multicast DNS resolver using AnyEvent framework.

=head1 METHODS

=over 4

=item discover

Run multicast DNS query and receive the services discovered with the
callback. The callback is passed with the service as a hash reference
with keys: C<host>, C<port>, C<proto> and C<name>.

The UDP socket for the DNS query times out in 3 seconds by default,
which you can change with C<timeout> parameter, and all the services
found are passed to the callback after the timeout.

  # receive all services in one shot, after 5 sec timeout
  my $cv = AnyEvent->condvar;
  AnyEvent::mDNS::discover $proto, timeout => 5, $cv;
  my @all_services = $cv->recv;

Although the timeout is done in a non-blocking way, you might want to
retrieve the service as soon as possible, in which case you specify
another callback with the key C<on_found>, then each service will be
passed to the callback as it's found.

  # receive service as it's found (faster)
  AnyEvent::mDNS::discover $proto, on_found => sub {
      my $service = shift;
      # ...
  }, $cv;
  $cv->recv;

You can obviously write your own AnyEvent timer loop to run this mDNS
query from time to time with smart interval (See the Multicast DNS
Internet Draft for details), to keep the discovered list up-to-date.

=back

=head1 AUTHOR

Tatsuhiko Miyagawa E<lt>miyagawa@bulknews.netE<gt>

=head1 LICENSE

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=head1 SEE ALSO

L<AnyEvent::DNS> L<http://files.multicastdns.org/draft-cheshire-dnsext-multicastdns.txt>

=cut
