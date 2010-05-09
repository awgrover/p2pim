#!/usr/bin/env perl
package p2pim::cli_test;
our $PKG = __PACKAGE__;

use strict; use warnings; no warnings 'uninitialized';
use Carp;
$SIG{ __DIE__ } = sub { Carp::confess( @_ ) };

use Verbose; $kVerbose = $ENV{'VERBOSE'};

use Net::BitTorrent;
use Data::Dumper;
use YAML ();
use IO::File;
use Digest::SHA qw[sha1_hex];

my $BootstrapTimeout = 20; # seconds
my $Respond_Time = 3;
my $Virgin = 1;
my $Old_Nodes = [];
my $My_Jabber_EndPoint;
my $bt;
my %Peers; # sha1=>[ip..]
my $LAN_IP;
my $Saved_State;

sub main {
    $My_Jabber_EndPoint = p2pim::cli_test::im_end_point->new(jabber_id => 'awgrover@jabber.org/p2p');
    verbose 0,"Jabber id; ",$My_Jabber_EndPoint->jabber_id, " => ",$My_Jabber_EndPoint->infohash;

    my $my_ip = 'localhost';

    loadState();

    my %setup;
    $setup{'LocalPort'} = $Saved_State->{'port'} if $Saved_State->{'port'};
    $bt = Net::BitTorrent->new(\%setup);

    restoreState();

    vverbose 0,"peer id ",$bt->peerid;
    vverbose 0,"on tcp port ",$bt->_tcp_host.":".$bt->_tcp_port;
    vverbose 0,"on udp port ",$bt->_udp_port;

    vverbose 0,"dht node id ",sprintf("%*v.2X",":",$bt->_dht->node_id);

    boostrapDHT();
    listen_and_respond();

    saveState();

    check_for_self();
    if (0 && ! $Peers{$My_Jabber_EndPoint->infohash}) {
        announceIM();
        listen_and_respond();
        check_for_self();
        }

    listen_and_respond(-1);
    }


sub check_for_self {
    my $sha = $My_Jabber_EndPoint->infohash;
    # $bt->torrents->{$sha} = $My_Jabber_EndPoint;
    $bt->_dht->_get_peers($sha, sub { _handle_get_peer_response(@_)});
    listen_and_respond();
    if (exists $Peers{$sha}) {
        vverbose 0,"Found peer ".$My_Jabber_EndPoint->jabber_id." (sha1 $sha)".join(", ",@{$Peers{$sha}});
        }
    else {
        vverbose 0,"Not found peer ".$My_Jabber_EndPoint->jabber_id." (sha1 $sha)";
        }
    }
    
sub announceIM {
    # we use the dht announce_peer to advertise our IM end-point
    # Instead of the torrent's sha1, we'll use the jabber-id's sha1
    my $sha = $My_Jabber_EndPoint->infohash;
    vverbose 0,"Jabber insert ",$My_Jabber_EndPoint->jabber_id," => ",$My_Jabber_EndPoint->infohash;
    $bt->_dht->_announce_sha1($sha);
    listen_and_respond();
    }

sub boostrapDHT {
    # blocking
    # should bootstrap off a peer, or .torrent
    # $bt->_dht->add_node( {ip => $my_ip, port => 49001} );

    my $start = time;
    vverbose 0,"Bootstrapping dht...";
    my $last = 0;
    while (time - $start < $BootstrapTimeout) {
        vverbose 0,"waiting ",(time - $start)," secs" if $last != time;
        $last = time;
        $bt->do_one_loop;
        last if @{$bt->_dht->nodes} > 1 && (time - $start) > 5;
        }
    die "DHT didn't bootstrap..." if @{$bt->_dht->nodes} <= 1;
    vverbose 0,"Have ".@{$bt->_dht->nodes}." dht nodes";
    # vverbose 0,"found Nodes ",join("\n\t",map {$_->{'ip'}.":".$_->{'port'}} @{$bt->_dht->nodes});
    }

sub listen_and_respond {
    # damn polling
    my $timeout = shift || $Respond_Time;
    my $start = time;
    vverbose 0,"Listening for $timeout secs...";
    my $last = 0;
    while ($timeout < 0 || time - $start < $timeout) {
        $bt->do_one_loop;
        vverbose 0,"." if $timeout > 0 && $last != time;
        $last = time;
        }
    }

sub _handle_get_peer_response {
    my ($sha1, $peers) = @_;
    vverbose 0, "Peer response! $sha1 : ",Dumper($peers);
    warn "The sha1(someuser)==$sha1 appears ".scalar(@$peers)." times" if @$peers > 1;
    $Peers{$sha1} = $peers;
    update_lan_ip($_) foreach @$peers;
    }

sub update_lan_ip {
    my ($new_ip) = @_;
    if (!$LAN_IP) {
        vverbose 0,"Found my lan address; $new_ip";
        }
    else {
        warn "Inconsistent report of lan address: had $LAN_IP, was told $new_ip" if $LAN_IP ne $new_ip;
        }
    # FIXME: we should register with ifup to get a hint that the IP may change
    # Which means we need to insert/get periodically to keep the cloud appraised
    $LAN_IP = $new_ip;
    }

sub loadState {
    my $stateH = IO::File->new("<.state") || die "can't read from .state, $!";
    $Saved_State = YAML::Load(join("",<$stateH>));
    $stateH->close;

    if (-e ".bootstrap") {
        my $bH = IO::File->new("<.bootstrap") || die "can't read from .bootstrap, $!";
        my $bootstrap = YAML::Load(join("",<$bH>));
        $bH->close;

        push @{$Saved_State->{'nodes'}}, @{$bootstrap->{'nodes'}}
        }
    }


sub restoreState {
    return if ! -e ".state";
    my $nodeIDH = IO::File->new("<.nodeid") || die "can't read from .nodeid, $!";
    my $node_id_hex = <$nodeIDH>;
    $nodeIDH->close;

    vverbose 0,"nodeid ".$node_id_hex;
    my @node_id_bytes = $node_id_hex =~ /([0-9a-f]{2})/gi;
    $bt->_dht->_set_node_id( pack( 'C*',map{hex $_} @node_id_bytes) );
    vverbose 0,"set dht node id ",sprintf("%*v.2X",":",$bt->_dht->node_id);

    $Old_Nodes = $Saved_State->{'nodes'};
    my $ct = 0;
    foreach (@{$Saved_State->{'nodes'}} ) {
        last if $ct++ >= 100;
        $bt->_dht->add_node($_);
        }
    $Virgin = undef;
    }

sub saveState {
    vverbose 0,"Saving State";
    my $nodeIDH = IO::File->new(">.nodeid") || die "can't write to .nodeid, $!";
    print $nodeIDH sprintf("%*v.2X","",$bt->_dht->node_id),"\n";
    $nodeIDH->close;

    my %state = (
        nodes => $bt->_dht->nodes,
        port => $bt->_tcp_port,
        );

    # at least 10 or include the old ones
    push @{$state{'nodes'}}, @{$Old_Nodes} if (@{$state{'nodes'}} < 10);
    my $stateH = IO::File->new(">.state") || die "can't write to .state, $!";
    print $stateH YAML::Dump(\%state);
    $stateH->close;
    }


##
###
##  Not Used
package p2pim::cli_test::im_end_point;
# behaves enought like a ::Torrent object to work
use Moose;
use Digest::SHA qw[sha1_hex];

has 'jabber_id' => (is => 'ro');

sub infohash {
    my $self=shift;
    sha1_hex($self->jabber_id);
    }

sub trackers {
    []
    }

no Moose;

no strict 'refs';
&{$PKG."::main"}();
