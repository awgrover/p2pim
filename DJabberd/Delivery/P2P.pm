package DJabberd::Delivery::P2P;
use strict;
use warnings;
use base 'DJabberd::Delivery';
use Digest::SHA qw(sha1_hex);
use Carp;

use DJabberd::Queue::ServerOut;
use DJabberd::Log;
use Danga::Socket;

# for mDNS
use AnyEvent::mDNS;
use AnyEvent::Blocker;
use Data::Dumper;
##

our $logger = DJabberd::Log->get_logger;

sub run_after { ("DJabberd::Delivery::Local") }

sub new {
    my $class = shift;
    my $self = $class->SUPER::new(@_);
    $self->{cache} = {}; # domain -> DJabberd::Queue::ServerOut

    $self->{'mDNS'} = AnyEvent::Blocker->new(new => 'Net::Rendezvous::Publish',
        backend => 'Net::Rendezvous::Publish::Backend::Avahi',
        sub { $logger->debug("Made ".shift) }
        );

    return $self;
}

sub deliver {
    my ($self, $vhost, $cb, $stanza) = @_;
    $logger->debug("P2P someone wants us to deliver ".$stanza->to_jid." : ".$stanza->as_xml);

    die unless $vhost == $self->{vhost}; # sanity check

    my $to = $stanza->to_jid
        or return $cb->declined;

    $self->{'mDNS'}->lookup(sha1_hex($to));

    my $domain = $to->domain;

    # don't initiate outgoing connections back to ourself
    if ($vhost->handles_domain($domain)) {
        return $cb->declined;
    }

    $logger->debug("s2s delivery attempt for $to");

    # FIXME: let get_conn_for_domain return an error code or something
    # which we can then pass along smarter to the callback, so client gets
    # a good error?
    my $out_queue = $self->get_queue_for_domain($domain) or
        return $cb->declined;

    $DJabberd::Stats::counter{deliver_s2s}++;
    $out_queue->queue_stanza($stanza, $cb);
}

sub get_queue_for_domain {
    my ($self, $domain) = @_;
    # TODO: we need to clean this periodically, like when connections timeout or fail
    return $self->{cache}{$domain} ||=
        DJabberd::Queue::ServerOut->new(source => $self,
                                        domain => $domain,
                                        vhost  => $self->{vhost});
}

### mdns debugging etc
  my @t;
sub set_config_localcheck {
  $logger->debug("Browsing for local p2p...");
  
  push @t, AnyEvent->timer(after => 0, interval => 5, cb => 
    sub {
      AnyEvent::mDNS::discover '_xmpp2p._tcp', 
        sub {
          foreach (@_) {
            $logger->debug(sprintf("\t%20s @%20s:%05.5d\n",$_->{'name'}, $_->{'host'}, $_->{'port'}));
            }
          };
        });
  }
1;
