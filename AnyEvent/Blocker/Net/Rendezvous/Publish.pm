# Extend Net::Rendezvous::Publish to be friendly with AnyEvent::Blocker
# Usage:
#   use AnyEvent::Blocker::Net::Rendezvous::Publish;
#   my $visible_proxy = AnyEvent::Blocker->new(new => 'Net::Rendezvous::Publish',
#      backend => 'Net::Rendezvous::Publish::Backend::Avahi',
#      sub { my $proxy=shift; $logger->debug("Made ".$proxy) }
#      );
#   $visible_proxy->class_stuff...
# publish() is around'd to return a service_id
# stop(service_id) is added to unpublish, i.e. as if $service->stop

package Net::Rendezvous::Publish;
# extend it
use Net::Rendezvous::Publish;
use Scalar::Util qw(refaddr);
use Verbose;
use Data::Dumper;

my $was;
BEGIN {$was = \&Net::Rendezvous::Publish::publish;
  delete $Net::Rendezvous::Publish::{'publish'}}
my %Services;


sub publish {
  my $service = &$was(@_);
  vverbose 0,"Published $service, saved as ".refaddr($service);
  $Services{refaddr $service} = $service;
  refaddr $service;
  }

sub stop {
  my $self=shift;
  # list of service_id's
  foreach my $service_id (@_) {
    if (exists $Services{$service_id}) {
      my $service = delete $Services{$service_id};
      vverbose 0,"Stopping service_id $service_id, ".$service;
      $service->stop;
      }
    else {
      vverbose 0,"Warning, tried to stop '$service_id', but not a known service handle: ".join(", ",keys %Services);
      undef;
      }
    }
  }

sub services {
  return keys %Services;
  }

1;
