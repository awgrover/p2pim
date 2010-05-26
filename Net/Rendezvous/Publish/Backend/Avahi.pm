package Net::Rendezvous::Publish::Backend::Avahi;

# vi: ts=4 sw=4

use strict;
use warnings;

use Net::DBus;

our $VERSION = 0.03;

sub new {
	my $class = shift;
	my $self = {@_};
	bless $self, $class;

	my $bus = Net::DBus->system;
	$self->{service} = $bus->get_service('org.freedesktop.Avahi');
	$self->{server} = $self->{service}->get_object(
		'/', 'org.freedesktop.Avahi.Server');

	return $self;
}

sub publish {
	my $self = shift;
	my %args = @_;

	my $group = $self->{service}->get_object(
		$self->{server}->EntryGroupNew, 'org.freedesktop.Avahi.EntryGroup');
	$group->AddService(Net::DBus::dbus_int32(-1), Net::DBus::dbus_int32(-1),
		Net::DBus::dbus_uint32(0), $args{name}, $args{type},
		$args{domain}, $args{host}, Net::DBus::dbus_uint16($args{port}),

		# AddService argument signature is aay.  Split first into key/value
		# pairs at character \x01, then map characters to bytes and add DBus
		# type.
		[map {
			[map {
				Net::DBus::dbus_byte(ord($_))
			} (split //, $_)]
		} (split /\x01/, $args{txt})]);
	$group->Commit;

	return $group;
}

sub publish_stop {
	my $self = shift;
	my ($group) = @_;

	$group->Free;
}

sub step {
}

1;

__END__

=head1 NAME

Net::Rendezvous::Publish::Backend::Avahi - Publish zeroconf data with the Avahi
library.

=head1 DESCRIPTION

This module publishes zeroconf data with the Avahi library.

It's a backend for the Net::Rendezvous::Publish module.

=head1 PREREQUISITES

Net::DBus

Net::Rendezvous::Publish

=head1 AUTHOR

Jack Bates <ms419@freezone.co.uk>

=head1 COPYRIGHT

Copyright 2006, Jack Bates.  All rights reserved.

This program is free software.  You can redistribute it and/or modify it under the same terms as Perl itself.

=head1 SEE ALSO

Net::Rendezvous::Publish - The module this module supports.

L<Avahi|http://avahi.org/>
