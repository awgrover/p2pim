package AnyEvent::Blocker;

=pod

Convert an library that blocks into AnyEvent callbacks, and eventloop compatibility.

=h1 Usage

  use EV; # or any other AnyEvent compatible
  use AnyEvent;

  # Create a thread, call Net::Bonjour->new(args...). Signal this thread in the callback.
  # This doesn't block!
  my $proxy = AnyEvent::Blocker->new( new => 'Net::Bonjour', args..., sub{my $proxy=shift; ...} );

  # Sends the method to the other thread, receives back the result
  # also, non-blocking.
  $proxy->someOtherMethod(1,2,3, sub{my ($data...)=@_; ...});

  Ev::loop; # or any other AnyEvent compatible

=h1 Outline

Basically puts the blocking module into an ithread. Then provides a proxy that sends methods 
and args to the thread via a Thread::Queue,
and gets back results the same way, but invokes your callback.

Each proxy creates a thread, so you can have multiple blocking-modules running in parallel.

Since the blocking-module is still blocking itself, only one method will run at a time for that instance.
That is, method calls are serialized:

  $proxy->listen('192.100.1.2', sub {blah blah});
  $proxy->write('some data');

The "write" is queued, but won't be invoked till the listen finishes.

The ithread model we run under implies:
  * You should only use coarse-grained, high level methods in the blocking-module.
  * You shouldn't pass lots of data around.

=h2 Caveats

Since the blocking-module is run in an ithread, you have to watch for interesting
"phase" issues. E.g.:
  * Moose attributes are created at run-time.
    Calling AnyEvent::Blocker->new() means any "has" that is lexically
    later won't take effect for the thread. I tried to test:

      my $proxy = AnyEvent::Blocker->new(new=>"Some::Package", sub{});
      # Notice that the "has", below, hasn't run yet.
      $proxy->x(sub{}); # no such method "x"
      ...
      package Some::Package;
      use Moose;
      has x => (is => 'ro'); # no-such method in the thread

=h1 Methods

All methods take a callback as the last argument. If you don't care, use

  sub{}

=h2 AnyEvent::Blocker->new( someMethodName => 'Some::Package', args..., \&callback($proxy) )

Creates a proxy object that runs blocking methods, without blocking the calling thread.

'someMethodName' is assumed to behave like new(): it must return an object for further
method calls. Note that a package name is fine, or anything that works with "->". If 
your blocking-module isn't OO, you'll have to write a wrapper.

The args may be any perl data, including nested structures. Note that the args are copied
(as per ithread) for the someMethodName() call.

Returns an AnyEvent::Blocker proxy object, for further method calls. The callback
gets the same object.

  * Returns a proxy object immediately
  * creates an ithread,
    * calls Some::Package->someMethodName(args...)
      Which may block the thread,
      and is used as the target for further method calls.
    * When the new() completes, 
      the callback will run in the parent ithread,
      with the proxy as the argument

=h2 $proxy->anythingElse( args..., \&callback($proxy) )

The method is queued for calling in the thread.

The method will be called on whatever someMethodName() gave above.

The args must be:
  * non-refs
  * or explicitly "shared" refs

The return value of the method has the same restrictions. You may have to write a wrapper
for the blocking-module to achieve this.

  my $proxy = AnyEvent::Blocker->new(initialize => 'Some::Package', blah, blah, sub{});
    # The thread remembers: my $object = Some::Package->initialize(blah, blah);
  $proxy->listen('192.100.1.2', sub {})
    # The 'listen' is queued
    # When the initialize finishes, 
    # the thread does this: my $result = $object->listen('192.100.1.2');
    # Notice the '$object'


=h1 Implementation

The outline is above. The trick to integrating with AnyEvent is finding a way to trigger
a watcher. I choose to put a watcher on a pipe, with AnyEvent::io. The blocking-module-thread
writes 1 character onto the pipe-writer when a method finishes. And the watcher is watching the pipe-reader. 
The character is ignored, it's just a signal.

I don't pass the callback routine into the thread. It's too hard to think about what ithreads will do to it.
And I don't want to call it in the thread anyway. Instead, I put the callback in a table, and pass that index
to the thread. When it enqueues the result, it includes the index so I can find the real callback ref and invoke it.

Since the arguments to new() are known at thread-create, they get copied by the ithreads semantics. I can behave like
it's a normal closure, thus
you can have any perl data. But, the arguments to methods aren't known till after the thread is running, and are passed
via Thread::Queue, so they have to have "shared" semantics.

Did I mention that I use AUTOLOAD() to proxy methods? So, I attempt to pass any and all methods to the blocking-module.
That's a bit fragile, as the thread will die on unknown methods. Don't even think about complaining that it's slow.

Did you notice that we are using ithreads? Slow to start, slow to communicate data, eats memory. So, don't expect this to give you
great performance. Why didn't I use Coro? 
  1. Coro isn't "real threads", Coro is co-routines. Grow up boys.
  2. Cooperative multi-tasking is so 1981. It just offends me.
  3. More telling, the cooperative'ness implies 
    re-writing a blocking-module to yield, etc. And,
    if you are going to do that, you don't need this hack: 
    just rewrite to be event loop friendly (cf. AnyEvent::DNS).

=h1 To Do

Consider allowing condition-variables.

Consider making the call-back optional.

Capture some exceptions (like method-unknown) and report them without killing the thread.

There is no provision for destroying the blocking-module-thread.

We initialize some stuff at compile time. Like the queues and pipe. 

And we force threads to exit individually.

=h1 See Also

AnyEvent

The Coro module has a pertinent critique of ithreads. On the other hand, the claim that "Coro is threads" is idiotic: they are coroutines (welcome to 1980: cooperative multi-tasking).

=cut

use threads 'exit' => 'threads_only';
use threads::shared;

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

# I make it a moose class var if:
#   it's really a singleton (all instances use it)
#   it's only used in this class
# I make it an OUR variable if:
#   The AnyEvent::Blocker::Wrapper uses it
use vars qw($AUTOLOAD);
class_has _callbacks => ( is => 'ro', default => sub{{}} );
class_has _callerid => ( is => 'rw', default => 0 );
# class_has _threads => ( is => 'ro', default => sub{[]} );
our $ResultQueue = Thread::Queue->new;
# notice order for handles, pipe, watcher
class_has _pipeReceive => ( is => 'ro', default => sub { my $h = IO::Handle->new; $h->autoflush(1); $h} );
our $PipeSend = IO::Handle->new;
$PipeSend->autoflush(1);
# never used as such, just want side-effect of the two ends
class_has _pipe => ( is =>'ro', default => sub {IO::Pipe->new($Package->_pipeReceive, $PipeSend) || die "can't make pipe $!"});
class_has _signaller => ( is => 'ro', default => sub { AnyEvent->io( fh => $Package->_pipeReceive, poll => 'r', cb => \&_doCallback )});

# instance
has _commandQueue => ( is => 'ro', default => sub{ Thread::Queue->new}, init_arg => undef );

sub _doCallback {
  # Not a class/object method!
  vverbose 0,"AnyEvent::Blocker::Wrapper sent signal!";
  while (my $todo = $ResultQueue->dequeue_nb) {
    # one "signal" for each queue entry
    my $tid = $Package->_pipeReceive->getc; # value is a signal, don't care. assume a char is there
    vverbose 0,"Signalled from thread $tid!";

    my $callerid = shift @$todo;
    vverbose 0,"Got result for callerid $callerid: ",Dumper($todo);
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
  vverbose 0,"Build from ".Dumper(\@_);
  my $args = $_[0]->{'args'};
  my ($newMethod, $class) = (shift @$args, shift @$args);
  my $cb = pop @$args;
  croak "last arg must be coderef: $cb" if ref($cb) ne 'CODE';

  vverbose 0,"Create wrapper for $class, and run in thread with new args: ".Dumper($args);

  # New gets called back with $self
  $self->_callerid($self->_callerid + 1); # that's right, this will eventually overflow.
  $self->_callbacks->{$self->_callerid} = sub{ &$cb($self) };
  # copy value for the cross-thread closure
  my $new_callerid=$self->_callerid;

  # push @{$self->_threads} , 
  threads->create(sub{ 
    # (It takes a looong time for this thread to start.)

    my $blockerPath = $class;
    $blockerPath =~ s/::/\//g;
    require $blockerPath.".pm";
    import $class;
    AnyEvent::Blocker::Wrapper::run($class->$newMethod(@$args), $new_callerid, $self->_commandQueue);

    # The module is probably blocked when we want to exit.
    # So, we detach and then we get no warnings when we tear Perl down
    })->detach;
  }

sub AUTOLOAD {
  # really we should:
  # have the same symbol table as the AnyEvent::Blocker::Wrapper, but with proxy methods
  # ---(args, \&cb)
  # The args shouldn't be nested structures (unless shared)

  my $self=shift;

  my $method = $AUTOLOAD;
  $method =~ s/^${Package}:://;
  warn "Proxying $method ".Dumper(\@_);

  my $cb = pop @_;
  croak "Last argument wasn't a code-ref!" if ref($cb) ne 'CODE';
  $self->_callerid($self->_callerid + 1); # that's right, this will eventually overflow.
  $self->_callbacks->{$self->_callerid} = $cb;
  
  my @command :shared; # (callerid, methodname, args)

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
use Verbose;
use Data::Dumper;

sub run {
  my ($object, $new_callerid, $commandQueue) = @_;

  vverbose 0,"Object $object created";
  # signal that NEW is done (which could be some init code)
  my @new_result :shared = $new_callerid;
  $ResultQueue->enqueue( \@new_result );
  $PipeSend->print(threads->tid); # just a signal
  vverbose 0,"Sent new-callback. Block in queue...";

  while (my $todo = $commandQueue->dequeue) {
    my ($callerid, $method) = (shift @$todo, shift @$todo);
    vverbose 0,"Command do: ${object}->$method ".Dumper($todo);
    my @result :shared = ($callerid, $object->$method(@$todo) );
    vverbose 0,"Command result queued: ${object}->$method ".Dumper(\@result);
    $ResultQueue->enqueue(\@result);
    $PipeSend->print(threads->tid); # just a signal
    }
  }

1;
