use threads 'exit' => 'threads_only';

package AnyEvent::Blocker;
my $Package = __PACKAGE__;
use strict; use warnings; no warnings 'uninitialized';
use Moose;
use Thread::Queue;
use MooseX::ClassAttribute;
use Data::Dumper;
use Verbose;
use IO::Pipe;
use AnyEvent;
use Carp;

use vars qw($AUTOLOAD);
class_has _callbacks => ( is => 'ro', default => sub{{}} );
class_has _callerid => ( is => 'rw', default => 0 );
class_has _threads => ( is => 'ro', default => sub{[]} );
our $ResultQueue = Thread::Queue->new;
class_has _pipeReceive => ( is => 'ro', default => sub { my $h = IO::Handle->new; $h->autoflush(1); $h} );
our $PipeSend = IO::Handle->new;
$PipeSend->autoflush(1);
my $Pipe = IO::Pipe->new($Package->_pipeReceive, $PipeSend) || die "can't make pipe $!";

sub _doCallback;
# must be "our" so it doesn't get GC'd
class_has _signaller => ( is => 'ro', default => sub { AnyEvent->io( fh => $Package->_pipeReceive, poll => 'r', cb => \&_doCallback )});

# instance
has _commandQueue => ( is => 'ro', default => sub{ Thread::Queue->new}, init_arg => undef );

sub _doCallback {
  # Not a class/object method!
  vverbose 0,"AnyEvent::Blocker::Wrapper signalled!";
  while (my $todo = $ResultQueue->dequeue_nb) {
    # one "signal" for each queue entry
    my $tid = $Package->_pipeReceive->getc; # value is a signal, don't care. assume a char is there
    vverbose 0,"Signalled from thread $tid!";

    my $callerid = shift @$todo;
    vverbose 0,"Got result for callerid $callerid";
    my $cb = delete __PACKAGE__->_callbacks->{$callerid};
    &$cb(@$todo);
    }
  }

sub BUILDARGS {
  my $class=shift;
  return { args => [ @_ ] }; # just pass through
  }

sub BUILD {
  my $self=shift;
  my $args = $_[0]->{'args'};

  vverbose 0,"Create wrapper and run in thread with new args: ".Dumper($args);
  push @{$self->_threads} , threads->create(sub{ 
    threads->detach;
    AnyEvent::Blocker::Wrapper->new(@$args)->run($self->_commandQueue);
    });
  }

sub AUTOLOAD {
  # really we should:
  # have the same symbol table as the AnyEvent::Blocker::Wrapper, but with proxy methods
  # ---(args, \&cb)
  # The args shouldn't be nested structures (unless shared)

  my $self=shift;

  warn "Proxying $AUTOLOAD ".Dumper(\@_);
  my $cb = pop @_;
  die "Last argument wasn't a code-ref!" if ref($cb) ne 'CODE';
  $self->_callerid($self->_callerid + 1); # that's right, this will eventually overflow.
  $self->_callbacks->{$self->_callerid} = $cb;
  
  my @command :shared; # (callerid, methodname, args)
  my $method = $AUTOLOAD;
  $method =~ s/^${Package}:://;

  push @command, ($self->_callerid, $method);
  push @command, map {
    if(ref($_)) {
      if(is_shared($_)) {
        $_;
        }
      else { 
        croak "Don't pass refs as args unless they are 'shared': $_";
        }
      }
    else { $_ }
    } @_;

  vverbose 0,"Enqueue command (callback ".$self->_callerid." -> $cb".Dumper(\@command);
  $self->_commandQueue->enqueue(\@command);
  }

sub print_queue {
  my $self=shift;
  print "Queue of ".$self->_commandQueue->pending.":\n";
  while (my $cmd = $self->_commandQueue->dequeue_nb) {
    print Dumper($cmd);
    }
  }

END {
  if ($ResultQueue->pending) {
    print "Unhandled results!\n";
    while (my $res = $ResultQueue->dequeue_nb) {
      print "Result: ".Dumper($res);
      }
    }
  }

no Moose;
no MooseX::ClassAttribute;

package AnyEvent::Blocker::Wrapper;
use Moose;
use Verbose;
use Data::Dumper;

sub BUILDARGS {
  my $class=shift;
  vverbose 0,"build blocker with ".Dumper(\@_);
  return {};
  }

sub run {
  my $self=shift;
  my ($commandQueue) = @_;

  while (my $todo = $commandQueue->dequeue) {
    my ($callerid, $method) = (shift @$todo, shift @$todo);
    vverbose 0,"Command do: $method ".Dumper($todo);
    my @result :shared = ($callerid, "saw $method");
    $ResultQueue->enqueue(\@result);
    $PipeSend->print(threads->tid); # just a signal
    }
  }

no Moose;

1;
