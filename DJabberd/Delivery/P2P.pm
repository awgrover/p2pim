package DJabberd::Delivery::P2P;
use strict;
use warnings;
use base 'DJabberd::Delivery';
use Digest::SHA qw(sha1_hex);
use Carp;

use DJabberd::Queue::ServerOut;
use DJabberd::Log;
use DJabberd::DNS; # for IPEndPoint
use Danga::Socket;

# for mDNS
use AnyEvent::mDNS;
use AnyEvent::Blocker;
use AnyEvent::Blocker::Net::Rendezvous::Publish;
use Data::Dumper;
##

our $logger = DJabberd::Log->get_logger;
our @RefHolder; # form anyEvent things that need a ref to persist
our @Instances; # for cleanup

use fields qw(mDNS vhost buddy_cache);

sub run_after { ("DJabberd::Delivery::Local") }

sub new {
  my $class = shift;
  my $self = $class->SUPER::new(@_);
  $self->{cache} = {}; # domain -> DJabberd::Queue::ServerOut
  $self->{'buddy_cache'} = {}; # sha1 -> [ ip, port ]

  $self->{'mDNS'} = AnyEvent::Blocker->new(new => 'Net::Rendezvous::Publish',
      backend => 'Net::Rendezvous::Publish::Backend::Avahi',
      sub { $logger->debug("Made ".shift) }
      );

  push @RefHolder, AnyEvent->timer(after => 0, interval => 1, cb => 
    sub {
      AnyEvent::mDNS::discover '_xmpp2p._tcp', 
        sub {
          $self->{'buddy_cache'} = {};
          foreach (@_) {
            $self->{'buddy_cache'}->{$_->{'name'}} = [ $_->{'ip'}, $_->{'port'} ];
            }
          };
        });

  push @Instances, $self; # for cleanup, messes with refcount
  $self->register_cleanup if scalar(@Instances) == 1;
  return $self;
}

sub register {
  my $self = shift;
  my ($vhost) = @_;
  $self->{'vhost'} = $vhost;
  $logger->debug("Registering for OnInitialPresence");
  $vhost->register_hook('OnInitialPresence',
    sub {
      my (undef, $cb, $conn) = @_;
      my $jid = $conn->{'bound_jid'}->as_bare_string;
      $jid .= '/'.$conn->{'bound_jid'}->resource if $conn->{'bound_jid'}->resource ne 'Home';

      $logger->debug("Saw!!! $jid from $conn(".ref($conn).")");
      $self->{'mDNS'}->publish(
        name => sha1_hex($jid),
        type => '_xmpp2p._tcp',
        port => $vhost->{'server'}->{'s2s_port'},
        domain => 'local',
        txt => $conn->{'bound_jid'}->as_string." as $jid",
        sub {$logger->debug("Published ".Dumper(\@_))}
        );
      $cb->decline;
      }
    );
  $logger->debug( "Registered for OnInitialPresence");

  $logger->debug("Registering for deliver");
  $vhost->register_hook('deliver',
    sub {
      $logger->debug("Saw 'deliver'!!");
      $self->deliver(@_);
      }
    );
  $logger->debug("Registered for deliver");
  }

sub deliver {
    my ($self, $vhost, $cb, $stanza) = @_;
    $logger->debug(sprintf("Asked to: Send %s from: %s to: %s (%s)",$stanza->innards_as_xml,$stanza->from, $stanza->to, sha1_hex($stanza->to)));

    die unless $vhost == $self->{vhost}; # sanity check

    my $to = $stanza->to_jid
        or return $cb->declined;

    $logger->debug("cache ".Dumper($self->{'buddy_cache'}));
    if (! exists $self->{'buddy_cache'}->{sha1_hex($to)}) {
      $logger->debug("Don't know where $to is (not in buddy_cache)");
      return $cb->declined;
      }

    my ($ip, $port) = @{ $self->{'buddy_cache'}->{sha1_hex($to)} };
    my $domain = $to->domain;

    # don't initiate outgoing connections back to ourself
    if ($vhost->handles_domain($domain)) {
        return $cb->declined;
    }

    $logger->debug("p2p delivery attempt for $to");

    # FIXME: let get_conn_for_domain return an error code or something
    # which we can then pass along smarter to the callback, so client gets
    # a good error?
    my $out_queue = $self->get_queue_for_domain($domain, $ip, $port) or
        return $cb->declined;

    $DJabberd::Stats::counter{deliver_s2s}++;
    $out_queue->queue_stanza($stanza, $cb);
}

sub get_queue_for_domain {
    my ($self, $domain, $ip, $port) = @_;
    $logger->debug("find/make Queue::ServerOut for domain $domain, $ip:$port");
    # TODO: we need to clean this periodically, like when connections timeout or fail
    return $self->{cache}{$domain} ||=
        DJabberd::Queue::ServerOut->new(source => $self,
                                        domain => $domain,
                                        vhost  => $self->{vhost},
                                        endpoints => [ DJabberd::IPEndPoint->new($ip, $port)]
                                        );
}

### mdns debugging etc
sub set_config_localcheck {
  my $self = shift;

  $logger->debug("Browsing for local p2p...");
  
  push @RefHolder, AnyEvent->timer(after => 0, interval => 30, cb => 
    sub {
      AnyEvent::mDNS::discover '_xmpp2p._tcp', 
        sub {
          $logger->debug("mDNS xmpp2p discovered: ".scalar(keys %{ $self->{'buddy_cache'} }));
          while (my ($sha1, $hp) = each %{ $self->{'buddy_cache'} }) {
            $logger->debug(sprintf("\t%20s @%20s:%05.5d\n",$sha1, $hp->[0], $hp->[1]));
            }
          };
        });
  }

sub register_cleanup {
  # Register a cleanup routine
  push @RefHolder, AnyEvent->signal(signal => 'TERM', cb => sub {
     warn("Running unpublish...");

      my $next_instance;
      $next_instance = sub {
        my $i = shift @Instances;
        if ($i) {
          $i->{'mDNS'}->services(sub {
            my @services = @_;
            warn "got services to stop ".join(", ",@services);
            if (@services) {
              $i->{'mDNS'}->stop(@services, sub { 
                warn("stopped: ",join(", ",@_));
                &$next_instance();
                });
              }
            else {
              warn("Instance $i had no services");
              &$next_instance();
              }
            });
          }
        else {
          warn( "Exiting $$ : ".threads->tid());
          exit 0;
          }
        };

      &$next_instance();

    }); 
  }
1;
