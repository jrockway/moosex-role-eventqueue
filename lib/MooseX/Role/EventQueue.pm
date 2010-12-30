package MooseX::Role::EventQueue;
# ABSTRACT: parameterized role implementing a set of attributes that maintain a queue of event handler callbacks, a default handler, and a queue of unhandled data
use MooseX::Role::Parameterized;
use true;
use namespace::autoclean;
use Try::Tiny;

parameter 'name' => (
    is       => 'ro',
    isa      => 'Str',
    required => 1,
);

# method name for injecting data; defaults to _handle_whatever
parameter 'method' => (
    is      => 'ro',
    isa     => 'Str',
    lazy    => 1,
    default => sub { '_handle_'. $_[0]->name },
);

# attribute that is the arrayref of callbacks to call when data is available;
# defaults to _whatever_handler_queue
parameter 'handler_queue_attribute' => (
    is      => 'ro',
    isa     => 'Str',
    lazy    => 1,
    default => sub { '_'. $_[0]->name. '_handler_queue' },
);

# attribute that is the arrayref of unhandled data; defaults to
# _whatever_data_queue/.
#
# TODO: allow this to be an arbitrary monoid, instead of an arrayref.
parameter 'data_queue_attribute' => (
    is      => 'ro',
    isa     => 'Str',
    lazy    => 1,
    default => sub { '_'. $_[0]->name. '_data_queue' },
);

# attribute that stores the default callback, to be called when there
# is no handler;  defaults to on_whatever
#
# you get an initarg, accessor, predicate, and clearer.  the predicate
# (has_on_whatver) is called internally, so don't rename it with +has
# or something.
parameter 'default_callback_attribute' => (
    is      => 'ro',
    isa     => 'Str',
    lazy    => 1,
    default => sub { 'on_'. $_[0]->name },
);

# delegates to setup on handler queue array; defaults to
# push_whatever, unshift_whatever, shift_whatever,
# has_pending_whatever_handler
#
# note that you must delegate at least shift and count; these are used
# internally!
parameter 'handler_queue_delegates' => (
    is       => 'ro',
    isa      => 'HashRef',
    lazy    => 1,
    default => sub {
        my $name = $_[0]->name;
        return +{
            "push_$name"                  => 'push',
            "unshift_$name"               => 'unshift',
            "shift_$name"                 => 'shift',
            "has_pending_${name}_handler" => 'count',
        };
    },
);

# delegates to setup on data queue array; defaults to
# shift_queued_whatever_data, has_queued_whatever_data
#
# note that you must delegate at least shift, psh, and count; these
# are used internally!
parameter 'data_queue_delegates' => (
    is      => 'ro',
    isa     => 'HashRef',
    lazy    => 1,
    default => sub {
        my $name = $_[0]->name;
        return +{
            "has_queued_${name}_data"   => 'count',
            "shift_queued_${name}_data" => 'shift',
            "push_queued_${name}_data"  => 'push',
        };
    },
);

# error_handler is a coderef called with an exception that a callback
# throws.  defaults to warn.
parameter 'error_handler' => (
    is      => 'ro',
    isa     => 'CodeRef',
    lazy    => 1,
    default => sub {
        my $name = $_[0]->name;
        return sub {
            my ($self, $error) = @_;
            my $cname = $self->meta->name;
            warn "$cname: error in $name callback (ignoring): $error";
        };
    },
);

role {
    my $role = shift;

    # ensure that we have all the delegates that we need
    my %handler_methods = reverse %{$role->handler_queue_delegates};
    confess 'need a handler shift delegate' unless $handler_methods{shift};
    confess 'need a handler count delegate' unless $handler_methods{count};

    my %data_methods = reverse %{$role->data_queue_delegates};
    confess 'need a data shift delegate' unless $data_methods{shift};
    confess 'need a data count delegate' unless $data_methods{count};
    confess 'need a data push delegate' unless $data_methods{push};

    # aliases for $self->$method_name calls (there are a lot of these,
    # which hopefully make the generated methods more readable.
    # hopefully.)
    my $has_data = $data_methods{count};
    my $get_data = $data_methods{shift};
    my $put_data = $data_methods{push};

    my $error_handler = $role->error_handler;
    my $cb_name = $role->default_callback_attribute;

    # this is what the trigger calls to process all queued data.  it's
    # a method that you can override.
    #
    # you can call it if you want to process all pending data with a
    # new callback.  not sure why you would do that, but it's
    # possible.
    my $handle_queued_data = "_handle_${cb_name}_trigger";
    method $handle_queued_data => sub {
        my ($self, $default_cb) = @_;
        confess 'need callback!' unless $default_cb;

        while($self->$has_data){
            try {
                my $data = $self->$get_data;
                $self->$default_cb(@$data);
            }
            catch {
                $self->$error_handler($_);
            };
        }
    };

    # this is the default handler's attribute ("on_whatever"). the
    # trigger will call the new-ly set callback with all queued data
    has $cb_name => (
        is        => 'rw',
        predicate => "has_$cb_name",
        clearer   => "clear_$cb_name",
        trigger   => sub {
            my ($self, $new, $old) = @_;
            return unless $new;
            $self->$handle_queued_data($new);
        },
    );

    # this is the queue of handler coderefs
    has $role->handler_queue_attribute => (
        isa     => 'ArrayRef[CodeRef]', # TODO: _CODELIKE, not CodeRef
        traits  => ['Array'],
        default => sub { +[] },
        handles => $role->handler_queue_delegates,
    );

    # this is the queue of data to be processed when we get some sort
    # of handler
    has $role->data_queue_attribute => (
        isa     => 'ArrayRef[ArrayRef]',
        traits  => ['Array'],
        default => sub { +[] },
        handles => $role->data_queue_delegates,
    );

    # a few more aliases
    my $has_handler = $handler_methods{count};
    my $get_handler = $handler_methods{shift};
    my $has_default_handler = "has_$cb_name";
    my $get_default_handler = $cb_name;

    # this is the method the user calls to inject data
    my $handler_method = $role->method;
    method $handler_method => sub {
        my ($self, @args) = @_;

        # prefer a queued handler, then the default handler, then nothing
        my $handler =
            $self->$has_handler ? $self->$get_handler :
            $self->$has_default_handler ? $self->$cb_name : undef;

        # if we got a handler, call it with the data
        if($handler){
            try {
                $self->$handler(@args);
            }
            catch {
                $self->$error_handler($_);
            };
        }
        # no handler, queue the data
        else {
            $self->$put_data([@args]);
        }

        return;
    };

    # we set up around watchers on anything that adds to the handler
    # queue, so that we can call the handler with pending data, if
    # there is some.
    my @handler_writers = grep { defined } map {
        $handler_methods{$_}
    } qw/push unshift/;

    if(@handler_writers){
        after @handler_writers => sub {
            my $self = shift;
            while(($self->$has_default_handler || $self->$has_handler)
                      && $self->$has_data){
                # while we have data or a handler, take it out of the
                # queue and reinvoke the handler method.  this will
                # not re-queue the data because we did the
                # prerequesite exists checks as the iteration
                # condition.
                my $data = $self->$get_data;
                $self->$handler_method(@$data);
            }
        };
    }
};
