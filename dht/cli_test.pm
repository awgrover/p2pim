#!/usr/bin/env perl
package p2pim::cli_test;
use strict; use warnings; no warnings 'uninitialized';
use Verbose; $kVerbose = $ENV{'VERBOSE'};

use Net::BitTorrent;
use Data::Dumper;

# my $ip_cmd = q#ifconfig `netstat -nr | egrep '^0.0.0.0' | awk '{print $8}'` | egrep '^ +inet ' | awk '{print $2}' | sed 's/addr://'#;
# my $my_ip = `$ip_cmd`;
#     chomp $my_ip;
my $my_ip = 'localhost';

my $bt = Net::BitTorrent->new;

vverbose 0,"peer id ",$bt->peerid;
vverbose 0,"on tcp port ",$bt->_tcp_host.":".$bt->_tcp_port;
vverbose 0,"on udp port ",$bt->_udp_port;
vverbose 0,"dht obj ",$bt->_dht;

vverbose 0,"dht node id ",join(":",unpack('c*',$bt->_dht->node_id));
$bt->_dht->add_node( {ip => $my_ip, port => 49001} );
vverbose 0,"start Nodes ",join("\n\t",map {$_->{'ip'}.":".$_->{'port'}} @{$bt->_dht->nodes});

my $start = time;
for ((1..4)) {
    vverbose 0,"loop at ",(time - $start)," secs";
    $bt->do_one_loop;
    # $bt->_dht->_find_node_out( {ip => 'localhost', port => 39768}, $bt->_dht->node_id);
    sleep 1;
    }
vverbose 0,"found Nodes ",join("\n\t",map {$_->{'ip'}.":".$_->{'port'}} @{$bt->_dht->nodes});

