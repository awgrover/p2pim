#!/usr/bin/env perl
package p2pim::cli_test;
use strict; use warnings; no warnings 'uninitialized';
use Verbose; $kVerbose = $ENV{'VERBOSE'};

use Net::BitTorrent;
use Data::Dumper;
use YAML ();
use IO::File;

my $BootstrapTimeout = 20; # seconds
my $Virgin = 1;
my $Old_Nodes = [];

# my $ip_cmd = q#ifconfig `netstat -nr | egrep '^0.0.0.0' | awk '{print $8}'` | egrep '^ +inet ' | awk '{print $2}' | sed 's/addr://'#;
# my $my_ip = `$ip_cmd`;
#     chomp $my_ip;
my $my_ip = 'localhost';

my $bt = Net::BitTorrent->new;

loadState();

vverbose 0,"peer id ",$bt->peerid;
vverbose 0,"on tcp port ",$bt->_tcp_host.":".$bt->_tcp_port;
vverbose 0,"on udp port ",$bt->_udp_port;
vverbose 0,"dht obj ",$bt->_dht;

vverbose 0,"dht node id ",sprintf("%*v.2X",":",$bt->_dht->node_id);

boostrapDHT();

saveState();

sub boostrapDHT {
    # blocking
    # should bootstrap off a peer, or .torrent
    # $bt->_dht->add_node( {ip => $my_ip, port => 49001} );

    my $start = time;
    verbose "Bootstrapping dht...";
    while (time - $start < $BootstrapTimeout) {
        vverbose 0,"loop at ",(time - $start)," secs";
        $bt->do_one_loop;
        last if @{$bt->_dht->nodes} > 1 && (time - $start) > 3;
        }
    die "DHT didn't bootstrap..." if @{$bt->_dht->nodes} <= 1;
    # vverbose 0,"found Nodes ",join("\n\t",map {$_->{'ip'}.":".$_->{'port'}} @{$bt->_dht->nodes});
    }

sub loadState {
    return if ! -e ".state";
    my $nodeIDH = IO::File->new("<.nodeid") || die "can't read from .nodeid, $!";
    my $node_id_hex = <$nodeIDH>;
    $nodeIDH->close;

    vverbose 0,"nodeid ".$node_id_hex;
    my @node_id_bytes = $node_id_hex =~ /([0-9a-f]{2})/gi;
    $bt->_dht->_set_node_id( pack( 'C*',map{hex $_} @node_id_bytes) );
    vverbose 0,"set dht node id ",sprintf("%*v.2X",":",$bt->_dht->node_id);

    my $stateH = IO::File->new("<.state") || die "can't read from .state, $!";
    my $state = YAML::Load(join("",<$stateH>));
    $stateH->close;

    $Old_Nodes = $state->{'nodes'};
    foreach (@{$state->{'nodes'}} ) {
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
        );

    # at least 10 or include the old ones
    push @{$state{'nodes'}}, @{$Old_Nodes} if (@{$state{'nodes'}} < 10);
    my $stateH = IO::File->new(">.state") || die "can't write to .state, $!";
    print $stateH YAML::Dump(\%state);
    $stateH->close;
    }
